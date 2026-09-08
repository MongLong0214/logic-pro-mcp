# Issue 683 — a stalled stdout write silently stops every reply, including timeout envelopes

Issue: [#683](https://github.com/MongLong0214/logic-pro-mcp/issues/683)
Size: **S for the guard, M with its test, because the test has to stall a real file descriptor and then prove the transport gave up on it rather than hanging the suite.**

Status: **specified, not implemented.** No commit and no test run is recorded here.

## 1. The measurement this rests on, and its limits

Reproduced 2026-09-08 on the release binary, macOS 26.3 (25D125), arm64. stdout was placed on a FIFO
held open by a reader that never reads — the shape of a client that stopped draining — then
`initialize`, `notifications/initialized`, and 39 `tools/list` requests, past a 64KB pipe buffer.

The process stays alive (`ps` state `R`) and answers nothing. `sample`:

```
1539 Thread_63151969   DispatchQueue_53: logic-pro-mcp.stdio.write  (serial)
  1539 closure #1 in SerializedStdioTransport.send(_:)                   SerializedStdioTransport.swift:88
    1539 closure #1 in static SerializedStdioTransport.writeAll(_:to:)   SerializedStdioTransport.swift:144
      1539 write  (in libsystem_kernel.dylib)
```

1539 of 1539 samples in the syscall — parked, not contended.

**What would change if the reading were about something else.** If the blocked frame were anywhere
but `writeAll`, this ticket is void. It is not: the stack names the file and line.

**Not measured:** that this is the reporter's hang. A real MCP host drains stdout; this reproduction
stopped it deliberately. What is established is that the mechanism is reachable in the shipped
binary and produces the reported symptom set exactly — no reply, no timeout envelope, no log line.

## 2. The decision this ticket makes

A deadline cannot be applied mid-frame. #220 exists because a frame written in pieces lets a second
frame interleave and corrupt the newline-delimited stream; abandoning a half-written frame is the
same corruption by another route. **So the wait is bounded before the first byte and never after
it**, and the residual — a client that stalls mid-frame — is made loud rather than fixed:

1. Before writing a frame, wait for the fd to become writable, with a deadline. If it does not, no
   byte of that frame has been written, so failing it is clean.
2. Once the first byte is out, finish the frame with the blocking write that is there today.
3. Arm a one-shot watchdog for the mid-frame case that logs to stderr with the frame size and the
   elapsed time, so the residual is visible instead of silent.

**Rejected: making the fd non-blocking and retrying on `EAGAIN`.** That is precisely the swift-sdk
behaviour #220 was written to escape — this transport's own header comment records that the retry's
`await` opened the reentrancy window that corrupted frames.

## 3. The change, exact

### 3.1 New: a writability wait

Add to `SerializedStdioTransport`, beside `writeAll`:

```swift
    /// Whether `fd` accepted a writer within `deadline`. Uses `poll` rather than a non-blocking
    /// write, because the point is to decide BEFORE any byte of the frame is committed: once a
    /// frame is part-written it must be finished or the stream is corrupted, which is the failure
    /// #220 exists to prevent.
    /// Why this returns a CASE and not a Bool: a Bool collapses "the deadline passed" with "the
    /// descriptor is invalid" and "the peer hung up", and `send` then reports every one of them as
    /// `OutputStalled` — a stalled reader. A closed descriptor is not a slow reader, and a caller
    /// that cannot tell them apart reports the wrong thing, which is the defect this whole ticket
    /// exists to remove from one layer down. Found by a merge-gate inventory 2026-09-08 in the
    /// Bool-returning version of this function.
    enum Writability { case ready; case timedOut; case failed(Int32) }

    private static func waitUntilWritable(_ fd: Int32, deadline: TimeInterval) -> Writability {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(0, min(deadline * 1000, Double(Int32.max))))
        while true {
            let n = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, milliseconds) }
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            if n == 0 { return .timedOut }
            if (pfd.revents & Int16(POLLNVAL)) != 0 { return .failed(EBADF) }
            if (pfd.revents & Int16(POLLERR)) != 0 { return .failed(EIO) }
            if (pfd.revents & Int16(POLLHUP)) != 0 { return .failed(EPIPE) }
            return (pfd.revents & Int16(POLLOUT)) != 0 ? .ready : .failed(EIO)
        }
    }
```

`POLLHUP` is `EPIPE` on purpose: the reader is gone, which is the ordinary end of a session and must
surface as the POSIX error a caller already handles, not as a novel stall type.

### 3.2 New: the error the transport reports

```swift
    /// The output stopped accepting bytes. Distinct from a POSIX error because nothing failed —
    /// the reader stopped reading, and a caller that cannot tell those apart reports the wrong
    /// thing.
    struct OutputStalled: Swift.Error, CustomStringConvertible {
        let bytes: Int
        let seconds: TimeInterval
        var description: String {
            "stdout did not accept a \(bytes)-byte frame within \(seconds)s: the reader has stopped "
                + "draining. No part of the frame was written."
        }
    }
```

### 3.3 Changed: `send`

**Before** (`SerializedStdioTransport.swift:83-94` at `bdf2b9a0`):

```swift
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            // Serial queue + blocking write ⇒ each frame is flushed atomically,
            // start-to-finish, before the next send's bytes touch the fd.
            writeQueue.async {
                do {
                    try SerializedStdioTransport.writeAll(frame, to: fd)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
```

**After:**

```swift
        let deadline = writeDeadline
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            // Serial queue + blocking write ⇒ each frame is flushed atomically,
            // start-to-finish, before the next send's bytes touch the fd.
            //
            // The wait for writability is BEFORE the first byte, and the write after it is still
            // blocking. Measured 2026-09-08: with a reader that stopped draining, this queue parked
            // in `write` for the whole sampling window and every later frame — replies and the 25s
            // timeout envelopes alike — queued behind it, with no log line and no error to any
            // caller. A transport that stops answering must say so.
            writeQueue.async {
                switch SerializedStdioTransport.waitUntilWritable(fd, deadline: deadline) {
                case .ready:
                    break
                case .timedOut:
                    cont.resume(throwing: OutputStalled(bytes: frame.count, seconds: deadline))
                    return
                case let .failed(code):
                    // A real descriptor failure, reported as the POSIX error it is. Collapsing this
                    // into OutputStalled would tell an operator the client stopped reading when the
                    // descriptor was closed.
                    cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                    return
                }
                let startedAt = DispatchTime.now()
                do {
                    try SerializedStdioTransport.writeAll(frame, to: fd)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                        - startedAt.uptimeNanoseconds) / 1_000_000_000
                    if elapsed > deadline {
                        // The residual this design does not remove: the reader stalled AFTER the
                        // frame began, so finishing it was the only safe move. Say so.
                        FileHandle.standardError.write(Data(
                            "[stdio] a \(frame.count)-byte frame took \(String(format: "%.1f", elapsed))s to write; the reader is stalling mid-frame\n".utf8))
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
```

### 3.4 New: the deadline, injectable

```swift
    /// Seconds to wait for stdout to accept a frame before declaring the output stalled. Injectable
    /// so a test can stall a real descriptor without stalling the suite.
    private let writeDeadline: TimeInterval

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil,
         writeDeadline: TimeInterval = 30) {
```

Assign `self.writeDeadline = writeDeadline` alongside the other stored properties. **30 seconds, not
5:** a large `tools/list` to a slow client is normal and must not be mistaken for a stall. The value
this ticket is defending against is infinity.

## 4. Call sites the change reaches

`SerializedStdioTransport(...)` is constructed **once**, at `LogicProServer.swift:1332`
(`let transport = SerializedStdioTransport()`). It takes the new default. Every other use is through
the `Transport` protocol and is unaffected — `send` keeps its signature and still throws.

`SerializedStdioTransport.writeAll` has **one** caller, `send`, unchanged by this ticket.

## 5. Acceptance criteria that can fail

1. A transport whose output is a pipe with **no reader draining it**, constructed with
   `writeDeadline: 0.2`, throws `OutputStalled` from `send` once the buffer is full — and the test
   completes in under 5 seconds rather than hanging.
2. `OutputStalled.bytes` equals the frame length including its trailing newline, and its
   `description` contains "No part of the frame was written."
3. After that throw, reading the pipe returns only **whole frames**: every byte read parses as
   newline-delimited JSON with no partial trailing object. This is the #220 property, asserted
   directly rather than assumed.
4. A transport whose output is drained normally sends 200 frames of ~4KB with no `OutputStalled` and
   no stderr line — the deadline does not fire on ordinary traffic.
5. Frames still do not interleave under concurrency: 50 concurrent `send`s of distinct 8KB frames to
   a drained pipe produce 50 whole frames, each intact.
6. `send` on a closed fd throws `POSIXError(.EBADF)`, not `OutputStalled`.
7. `send` to a pipe whose read end was closed throws `POSIXError(.EPIPE)`, not `OutputStalled` — the
   reader is gone, which is not the reader being slow.
8. `send` to a full pipe with a live but non-draining reader throws `OutputStalled`. Criteria 6, 7
   and 8 are three different causes and must produce three different errors; a Bool return made all
   three identical, which is why they are separate criteria rather than one.

## 6. Mutations that must turn a named test RED

| mutation | test that must go red |
|---|---|
| delete the `waitUntilWritable` guard | criterion 1 — the test hangs instead of throwing, so it must be written with a bounded wait and fail on timeout |
| return `true` unconditionally from `waitUntilWritable` | criterion 1 |
| move the guard inside `writeAll`'s loop (per chunk) | criterion 3 — a partial frame reaches the pipe |
| set the default `writeDeadline` to `0` | criterion 4 |
| report `frame.count - 1` as `OutputStalled.bytes` | criterion 2 |
| drop the serial queue and write from the calling thread | criterion 5 |
| return `.timedOut` where `waitUntilWritable` returns `.failed` | criteria 6 and 7 — both would report a stalled reader |
| map `POLLHUP` to `.ready` | criterion 7 — the write proceeds into a closed pipe |

## 7. Not in scope

- **Making the mid-frame stall recoverable.** It cannot be, without breaking frame atomicity. It is
  logged and that is all this ticket does about it.
- **Whether MCU feedback can make a client stop draining.** Unmeasured, and the first theory about
  it was wrong: notifications are published from the poller's `postPoll`, not per MIDI packet.
- **The read side.** `readLoop` runs on its own Thread with blocking reads and is not implicated.
- **Back-pressure or dropping frames when the client is slow.** A different design question; this
  ticket only replaces an unbounded wait with a bounded one.

## 8. What this ticket does NOT establish

- That it fixes #683 as reported. It removes a mechanism that produces the reported symptoms
  exactly; the reporter's host has not been observed.
- That 30 seconds is the right deadline. No measurement of real client drain latency was taken; the
  number is chosen to be far outside normal traffic and finite, and it is injectable so it can be
  changed on evidence rather than on argument.
- That `OutputStalled` reaches anywhere useful. Where the server surfaces a transport error to the
  operator was not examined, and a thrown error nobody prints would repeat the defect in a new place.
