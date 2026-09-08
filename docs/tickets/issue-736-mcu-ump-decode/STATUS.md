# Issue 736 — MCU feedback is decoded as if UMP words were a MIDI 1.0 byte stream

Issue: [#736](https://github.com/MongLong0214/logic-pro-mcp/issues/736) (also bears on #683)
Record: [2026-09-08-mcu-feedback-is-decoded-as-if-it-were-midi-1](../../observations/2026-09-08-mcu-feedback-is-decoded-as-if-it-were-midi-1.json)
Size: **M, because the conversion itself is one function and the two consumers are already correct — the cost is the fixture rebuild, since the existing test encodes the same mistake and cannot be adapted, only replaced.**

Status: **specified, not implemented.** No commit, no test run, no live re-measurement is recorded here.

## 1. The measurement this rests on, and its limits

Captured 2026-09-08 with `MCU_TRACE=1` on the release binary against Logic Pro 12.3 (6674), macOS
26.3 (25D125), UI language `en`, with the Mackie Control surface bound to `LogicProMCP-MCU-Internal`
(`com.apple.logic.pro.cs` carries `Mackie Control` and the port name twice, in and out). The capture
is `docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json` — 161 RX frames, 2 TX, verbatim
and in order.

Replaying that capture through a faithful port of the shipped parser and through a UMP-correct read:

```
packets Logic sent                            161
events the shipped read produces                8      all channel pressure, all misvalued
events a UMP-correct read produces            121
```

**What would change if the reading were about something else.** The whole ticket rests on the bytes
in that capture being the little-endian memory image of UMP words. If they were something else — a
trace formatting artefact, say — then the conversion below is wrong and the ticket is void. Two
independent checks say they are not: the same shapes appear in the reporter's own sniff on a
different machine (`20D00000`, `30050000 66140000`), and the decoded values are coherent MCU state
(eight consecutive meters with a rising strip index; nine faders at one value).

**Not measured:** that correcting the decode makes echo verification pass. Zero packets arrived
after our own fader write, and `MCUProtocol` has no encoder for the connection reply Logic's
handshake expects. This ticket fixes what is provably broken; it does not claim State A becomes
reachable.

## 2. The change, exact

### 2.1 New: `MIDIFeedback.midi1Bytes(fromUMPWords:)`

Add to `Sources/LogicProMCP/MIDI/MIDIFeedback.swift`, immediately after `parseBytes`.

```swift
    /// Convert one CoreMIDI Universal MIDI Packet into the MIDI 1.0 byte stream `parseBytes` reads.
    ///
    /// The port is created with `MIDIDestinationCreateWithProtocol(..., ._1_0, ...)`, so CoreMIDI
    /// delivers MIDI 1.0 messages wrapped in 32-bit UMP words. A word's LAYOUT and its byte order
    /// in memory are different things: the word is
    ///
    ///     (0x2 << 28) | (group << 24) | (status << 16) | (data1 << 8) | data2
    ///
    /// and on a little-endian host its bytes are `[data2, data1, status, 0x20|group]`. Slicing the
    /// memory image and calling it a MIDI stream reverses every message. Measured 2026-09-08:
    /// 161 packets from Logic produced 8 events instead of 121, and every fader position was
    /// dropped, because a four-byte packet puts the status at index 2 and leaves one byte after it
    /// — enough for channel pressure's guard and not for anything with two data bytes.
    ///
    /// Returns the messages this converter understands, concatenated. Words it does not convert are
    /// reported in `unconverted` so a caller can say how much it did not read, rather than
    /// presenting a partial decode as a complete one.
    static func midi1Bytes(fromUMPWords words: [UInt32]) -> (bytes: [UInt8], unconverted: Int) {
        var out: [UInt8] = []
        var unconverted = 0
        var i = 0
        while i < words.count {
            let w = words[i]
            let messageType = UInt8((w >> 28) & 0xF)
            switch messageType {
            case 0x0:                       // utility — carries no MIDI 1.0 message
                i += 1
            case 0x1, 0x2:                  // system real-time/common, and channel voice
                let status = UInt8((w >> 16) & 0xFF)
                let data1 = UInt8((w >> 8) & 0x7F)
                let data2 = UInt8(w & 0x7F)
                switch dataByteCount(forStatus: status) {
                case 0: out.append(status)
                case 1: out.append(contentsOf: [status, data1])
                default: out.append(contentsOf: [status, data1, data2])
                }
                i += 1
            case 0x3, 0x4:                  // 64-bit: SysEx7 data, and MIDI 2.0 channel voice
                unconverted += 1
                i += 2
            case 0x5:                       // 128-bit
                unconverted += 1
                i += 4
            default:
                unconverted += 1
                i += 1
            }
        }
        return (out, unconverted)
    }

    /// How many data bytes a MIDI 1.0 status byte carries. `0` for a status that carries none.
    private static func dataByteCount(forStatus status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch status {
            case 0xF1, 0xF3: return 1
            case 0xF2: return 2
            default: return 0          // real-time, tune request, and SysEx framing bytes
            }
        default: return 2
        }
    }
```

**Why the word stride matters and is not cosmetic.** A packet can carry several messages. Advancing
by one word past a 64-bit message would read its second word as a new message header, which is how a
conversion bug becomes a fabricated event rather than a missing one.

### 2.2 Changed: the receive callback

`Sources/LogicProMCP/Server/LogicProServer.swift`, inside `createBidirectionalPort`'s closure.

**Before** (lines 1529-1531 at `bdf2b9a0`):

```swift
                        let bytes: [UInt8] = withUnsafeBytes(of: packetPtr.pointee.words) { raw in
                            Array(raw.prefix(wordCount * 4))
                        }
```

**After:**

```swift
                        let umpWords: [UInt32] = withUnsafeBytes(of: packetPtr.pointee.words) { raw in
                            Array(raw.bindMemory(to: UInt32.self).prefix(wordCount))
                        }
                        let converted = MIDIFeedback.midi1Bytes(fromUMPWords: umpWords)
                        let bytes = converted.bytes
                        if converted.unconverted > 0 {
                            sink.recordUnconvertedWords(UInt64(converted.unconverted))
                        }
```

The `MCUTrace.emit(.rx, bytes)` call on the following line **stays where it is and now traces the
converted MIDI 1.0 bytes.** That is a deliberate change of what the trace shows: the trace exists to
say what the parser sees, and after this change what it sees is the converted stream. Add to
`MCUTrace`'s header comment: *"RX frames are the MIDI 1.0 bytes converted from the packet's UMP
words, not the words' memory image."*

### 2.3 New: `recordUnconvertedWords`, on BOTH types in the chain

The call site is `sink.recordUnconvertedWords(...)`, and `sink` is
`LogicProServer.FeedbackSink` (`LogicProServer.swift:1405`) — **not** `MCUFeedbackIngress`. An
earlier draft of this ticket named only the ingress type, which would have sent an implementer to
the wrong file for the call it had just written; a merge-gate inventory caught it 2026-09-08. The
counter travels the same chain `recordCallbackWorkBudgetDrop` already travels, so both ends change:

1. **`FeedbackSink.recordUnconvertedWords(_ count: UInt64)`** (`LogicProServer.swift`, beside
   `recordCallbackWorkBudgetDrop` at `:1437`), forwarding to the ingress exactly as that one does.
   Note the argument label: the sink's methods take an unlabelled `_ count`, the ingress's take
   `count:`. Copying one signature onto the other type is the mistake this section exists to stop.
2. **`MCUFeedbackIngress.recordUnconvertedWords(count: UInt64)`**
   (`Sources/LogicProMCP/Channels/MCUChannel.swift`, beside `recordCallbackWorkBudgetDrop` at
   `:139`) — same lock discipline, same "does not kill the ingress" semantics.

Then add the count to `MCUFeedbackIngressSnapshot` and append to the existing `workBudgetDetail`
string in `healthCheck()`:

```swift
        let unconvertedDetail = ingress.unconvertedWordCount > 0
            ? "; \(ingress.unconvertedWordCount) UMP word(s) carried a message this server does not convert"
            : ""
```

`unconverted` is **not** an error and must not make MCU unavailable. Under the scope below it is the
expected count for SysEx traffic, and a health field that says so is the difference between a known
gap and a silent one.

## 3. Call sites the change reaches

`MIDIFeedback.parseBytes` has **two** callers. Counted and classified:

| caller | file | classification |
|---|---|---|
| `MIDIFeedback.parse(packetList:into:)` | `MIDIFeedback.swift:30` | **unchanged, and must stay unchanged.** Its input is a legacy `MIDIPacketList`, whose `data` really is a MIDI 1.0 byte stream. Converting there would break the one caller that is already right. |
| the MCU receive callback | `LogicProServer.swift:1542` | the change above |

`withUnsafeBytes(of: packetPtr.pointee.words)` appears **once** in `Sources/`. No other code reads
UMP words.

## 4. Acceptance criteria that can fail

1. `MIDIFeedback.midi1Bytes(fromUMPWords: [0x20D01000])` returns bytes `[0xD0, 0x10]` and
   `unconverted == 0`. (Under the old path this input produced `[0x00, 0x10, 0xD0, 0x20]`.)
2. `midi1Bytes(fromUMPWords: [0x20E81B61])` returns `[0xE8, 0x1B, 0x61]`, and feeding that to
   `parseBytes` yields exactly one `.pitchBend(channel: 8, value: 12443)`.
3. Replaying every RX frame in `docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json`
   through `midi1Bytes` then `parseBytes` yields **112** events: 8 channel pressure, 20 control
   change, 73 note on, 11 pitch bend. The eleven pitch bends are `ch0…ch8 = 12443`, `ch9 = 0`,
   `ch0 = 8192`, in that order.

   **These numbers were produced, not predicted.** `Scripts/mcu-ump-reference-decode.py` is a
   reference decode of the same capture and ASSERTS them — class counts, the unconverted total, and
   the eleven decoded pitch-bend payloads. It printed the payloads without checking them until a
   merge-gate inventory pointed out that an oracle which only prints a value cannot disagree about
   it. It is an oracle for the life of this ticket, not a second
   implementation to keep in sync — delete it when the ticket closes.
4. The same replay reports **exactly 96** unconverted words (the SysEx traffic), and MCU health
   remains `available` with the unconverted count named in its detail string.

   Exactly 96, because `> 0` cannot see a wrong word stride. Measured while mutation-testing the
   oracle: advancing one word past a 64-bit message makes its second word look like a header, those
   continuation words land in `unconverted`, and **the event counts do not move at all** — the
   stride bug passed a `> 0` check and fails an exact one. Criterion 6 still carries the case this
   capture cannot show, where the second word decodes as a plausible channel-voice header and
   fabricates an event.
5. A two-message packet `[0x20B03010, 0x20E80040]` yields both a `.controlChange` and a
   `.pitchBend`, in that order — proving messages are not lost when a packet carries more than one.
6. A packet whose first message is 64-bit (`[0x30160000, 0x66142000, 0x20903C64]`) yields exactly
   one `.noteOn` and `unconverted == 1` — proving the word stride skips the second word of a 64-bit
   message rather than counting it separately.

   **Corrected after a merge-gate inventory.** This criterion used to say the wrong stride would
   "fabricate an event". It would not, for THIS packet: `0x66142000`'s message type is `6`, which no
   branch converts, so a one-word stride miscounts `unconverted` and produces no extra event. The
   fabrication case needs a continuation word whose top nibble is `1` or `2`, and it is criterion 7.

7. A packet `[0x30060000, 0x20903C64]` — a 64-bit header whose SECOND word is itself a valid
   channel-voice pattern — yields exactly one `.noteOn`, not two. With a one-word stride the second
   word is read as a header and an event is FABRICATED rather than miscounted, which is the failure
   the stride exists to prevent.

8. `midi1Bytes(fromUMPWords: [0x209040FF])` masks its data bytes to 7 bits: the result is
   `[0x90, 0x40, 0x7F]`, not `[0x90, 0x40, 0xFF]`. **Criterion 2 cannot witness this** — its word
   `0x20E81B61` has data bytes `0x1B` and `0x61`, neither with bit 7 set, so `0x7F` and `0xFF` give
   the same answer. A mutation whose named witness cannot move is a mutation nobody tested.
7. `MIDIFeedback.parse(packetList:into:)`'s existing tests pass **unchanged**, with no edit to that
   function.

Every one of 1-6 is checked against the live capture or against a word this ticket writes out in
full, so none of them can be satisfied by a fixture that agrees with the implementation.

## 5. Mutations that must turn a named test RED

| mutation to production code | test that must go red |
|---|---|
| revert 2.2 to slicing the memory image | criterion 3 — the replay yields 8 events, not 112 |
| in `midi1Bytes`, emit `[data2, data1, status]` instead of `[status, data1, data2]` | criterion 2 |
| in `dataByteCount`, return 2 for `0xD0` | criterion 1 |
| in `dataByteCount`, return 1 for `0xE0` | criterion 2 |
| advance `i += 1` for message type `0x3` | criterion 6 — the second word decodes as a spurious message |
| return after the first message instead of looping | criterion 5 |
| mask data bytes with `0xFF` instead of `0x7F` | **a new criterion 8**, not criterion 2 — see below |

A mutant that leaves every test green means that criterion is not being tested, and the ticket is
not done.

## 6. Not in scope

- **SysEx7 reassembly (message type 0x3).** It needs cross-packet state and a bound on a partial
  frame, which is a different problem from a word-order conversion. Its only consumer is
  `MCUProtocol.decodeLCDSysEx` → `cache.updateMCUDisplayRow`, i.e. the LCD text rows. Those are
  **already** lost today, so deferring them is not a regression; it is the same gap, now counted.
- **The connection-reply encoder.** `MCUProtocol` answers no Host Connection Query. That may be why
  no packets follow our fader write. It is a separate ticket and this one must not grow into it.
- **Changing `parseBytes`.** It is correct for its legacy caller and correct for a properly converted
  stream. Rewriting it to consume UMP directly would drop the running-status and SysEx handling that
  `MIDIFeedbackStatusByteTests` and `Issue683MCUFeedbackLivenessTests` cover.
- **`MCURestartFeedbackTests`' restart semantics.** Only its `firePitchBend` fixture is wrong; what
  the suite asserts about restart is not.

## 7. What this ticket does NOT establish

- That MCU echo verification becomes reachable. It removes one proven cause; the fader-write echo
  did not arrive at all in the capture, and the handshake gap above is unexamined.
- That `registered_as_device` becomes meaningful. It goes true today off eight misvalued packets;
  after this change it will go true off correct ones, which is better evidence for the same claim
  but not a new claim.
- That the reporter's host behaves like this one. Their `connected:false` is consistent with a
  decode that yields nothing at all, but consistency is not a measurement of their machine.
- That 121 is the right total. Nine of those words decode to a status nibble that is not a
  channel-voice one; they are excluded from criterion 3's 112 and were never chased.

## 8. Fixture that must be replaced, not adapted

`Tests/LogicProMCPTests/MCURestartFeedbackTests.swift:59`

```swift
        let word = UInt32(status) | (UInt32(lsb) << 8) | (UInt32(msb) << 16)
```

with the comment at `:52` stating the intent — *"The crafted UMP word's little-endian bytes are
`[status, lsb, msb, 0]` — exactly what the callback slices out"*. That is a MIDI 1.0 byte stream laid
into a word, which is not a UMP message; the fixture was written to match the implementation rather
than the contract, which is why it passes on input Logic never sends. Replace with

```swift
        let word = (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(lsb) << 8) | UInt32(msb)
```

and update the comment to say what it now builds and why. **Do not keep the old fixture alongside the
new one.** A suite that accepts both shapes has no opinion about which one CoreMIDI delivers.
