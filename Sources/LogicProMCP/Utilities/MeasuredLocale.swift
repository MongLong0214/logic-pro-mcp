/// The Logic UI languages a read path has actually been measured against.
///
/// This was `QualificationLocale`, declared inside the release-certification code and used by one
/// product guard: `TempoMapAX.requireMeasuredLocale` refuses a tempo read on a Logic whose language
/// nobody has measured, rather than returning a number parsed by guesswork. The certification
/// system is gone; the refusal is product behaviour a caller sees, so the type moves here.
///
/// Adding a case is a claim that someone measured that locale's tempo surface. It is not a list of
/// languages the product has labels for — `AXLocalePolicy` is that, and it is larger.
///
/// Two of the ten languages Logic ships, and that is the honest number. `AXLocalePolicy` reaches
/// ten because Apple's rows do; the tempo surface has been READ in exactly two -- en-US in the
/// arrange-menus census of 2026-09-12, ko-KR in the set-tempo observation of 2026-09-14 -- and
/// widening this to match the labels would be claiming eight measurements nobody took.
enum MeasuredLocale: String, CaseIterable, Sendable {
    case enUS = "en-US"
    case koKR = "ko-KR"

    /// Whether a Logic UI language identifier is one of these.
    ///
    /// The guard that refuses an unmeasured locale used to compare against `enUS.rawValue` and
    /// `koKR.rawValue` written out by hand, so adding a case here would have changed what this
    /// type SAYS and not what the product DOES -- a named site and an enforcement site drifting
    /// apart, which is the defect this repository keeps finding. One reader, here.
    static func isMeasured(_ identifier: String) -> Bool {
        MeasuredLocale(rawValue: identifier) != nil
    }
}
