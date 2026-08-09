import Foundation

/// Shared "Logic owns the keyboard and the window server" precondition (#440 D).
///
/// Keystrokes routed through CGEvent were the first place this mattered — one posted while Logic is
/// in the background is swallowed, and the caller saw a sent-but-unverified success for something
/// Logic never received. Measured on the release artifact, the AX transport path has the same
/// exposure for a different reason: `goto_position` driven from the background lands on the wrong
/// bar (requested 1.1.1.1, observed 3.3.1.1 and 2.3.1.1 on two runs, against 2/2 exact hits with
/// Logic frontmost). It reports that honestly as State B, but it has already moved the playhead.
///
/// So the gate belongs to any operation that drives Logic's UI, not to one channel. It lives here so
/// both use the same algorithm rather than two drifting copies.
enum FrontmostGate {
    enum Preparation: String, Sendable {
        /// Logic already owned the keyboard; nothing was activated.
        case alreadyFrontmost = "already_frontmost"
        /// Logic was in the background and came forward within the bound.
        case activated = "activated"
        /// Logic did not become frontmost within the bound. Nothing was actuated.
        case activationTimedOut = "activation_timed_out"
        /// The activation call itself refused. Nothing was actuated.
        case activationRefused = "activation_refused"

        var isReady: Bool { self == .alreadyFrontmost || self == .activated }
    }

    /// Consecutive frontmost observations required before acting. A single reading can catch the
    /// window server mid-switch, which is exactly the race that makes an actuation land nowhere.
    static let requiredObservations = 2
    /// Bound on how long activation is given, as a count of polls.
    static let maximumActivationPolls = 20
    /// Delay between polls.
    static let activationPollMicros: UInt32 = 50_000

    /// Brings Logic forward if needed and reports what happened. Performs no actuation of its own
    /// beyond the activation call, so a caller that refuses on a non-ready result has done nothing.
    static func prepare(
        isFrontmost: () -> Bool,
        activate: () -> Bool,
        sleepMicros: (UInt32) -> Void
    ) -> Preparation {
        if consecutiveObservations(isFrontmost: isFrontmost, sleepMicros: sleepMicros) >= requiredObservations {
            return .alreadyFrontmost
        }
        guard activate() else { return .activationRefused }
        for _ in 0..<maximumActivationPolls {
            sleepMicros(activationPollMicros)
            if consecutiveObservations(isFrontmost: isFrontmost, sleepMicros: sleepMicros) >= requiredObservations {
                return .activated
            }
        }
        return .activationTimedOut
    }

    private static func consecutiveObservations(
        isFrontmost: () -> Bool,
        sleepMicros: (UInt32) -> Void
    ) -> Int {
        var seen = 0
        for _ in 0..<requiredObservations {
            guard isFrontmost() else { return 0 }
            seen += 1
            if seen < requiredObservations {
                sleepMicros(activationPollMicros)
            }
        }
        return seen
    }
}
