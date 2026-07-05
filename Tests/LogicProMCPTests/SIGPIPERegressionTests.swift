import Darwin
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// P0 regression: before the fix the server died with signal 13 (SIGPIPE) the
/// instant an MCP client closed the read end of our stdout mid-frame, because
/// `SerializedStdioTransport` writes with a raw `Darwin.write`, whose default
/// broken-pipe disposition terminates the process. `MainEntrypoint`
/// installs `signal(SIGPIPE, SIG_IGN)` at startup so a broken-pipe write instead
/// returns `-1`/`EPIPE(32)` — an error the write loop already surfaces.
///
/// These tests replicate the audit's empirical proof. They install the EXACT
/// production guard (`MainEntrypoint.ignoreBrokenPipeSignal()`) and then write
/// to a pipe whose read end is closed. FLIP-TEST: gut the body of
/// `ignoreBrokenPipeSignal()` and this suite fails — the broken-pipe write
/// delivers SIGPIPE and kills the test process before any assertion runs.
@Suite("SIGPIPE regression (#P0 broken-pipe survival)")
struct SIGPIPERegressionTests {
    /// Both proofs live in ONE test so there is no inter-test race on the
    /// process-global signal disposition: reset to default first, install the
    /// production guard, then prove a broken-pipe write survives twice — once at
    /// the raw syscall level, once through the real transport send path.
    @Test("broken-pipe write returns EPIPE(32) and the process survives")
    func brokenPipeWriteSurvives() async throws {
        // Clear any ambient disposition so the flip-test is deterministic: with
        // the guard removed, SIGPIPE stays at its default (kill) disposition.
        signal(SIGPIPE, SIG_DFL)
        MainEntrypoint.ignoreBrokenPipeSignal()

        // --- Proof 1: raw Darwin.write to a pipe with the read end closed ---
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let rawWriteEnd = fds[1]
        close(fds[0]) // break the pipe: no reader remains

        let payload: [UInt8] = Array("frame\n".utf8)
        let rawResult = payload.withUnsafeBytes { Darwin.write(rawWriteEnd, $0.baseAddress, $0.count) }
        let rawErrno = errno // capture immediately, before any other libc call
        close(rawWriteEnd)

        #expect(rawResult == -1) // write failed instead of killing us
        #expect(rawErrno == EPIPE) // EPIPE == 32 on Darwin — the audit's exact code
        #expect(EPIPE == 32) // pin the numeric value the P0 audit reported

        // --- Proof 2: the real transport send path surfaces the same EPIPE ---
        var transportFDs: [Int32] = [-1, -1]
        #expect(pipe(&transportFDs) == 0)
        let transportWriteEnd = transportFDs[1]
        close(transportFDs[0]) // break the pipe before the transport writes

        let transport = SerializedStdioTransport(output: transportWriteEnd)
        var caught: (any Error)?
        do {
            try await transport.send(Data("{\"jsonrpc\":\"2.0\"}".utf8))
        } catch {
            caught = error
        }
        close(transportWriteEnd)

        // send() must have thrown a POSIX EPIPE (the write loop's error), not
        // let SIGPIPE kill the process. Bind + force-unwrap per house style.
        let posix = try #require(caught as? POSIXError)
        #expect(posix.code == .EPIPE)
    }
}
