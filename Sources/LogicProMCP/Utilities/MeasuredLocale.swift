/// The Logic UI languages a read path has actually been measured against.
///
/// This was `QualificationLocale`, declared inside the release-certification code and used by one
/// product guard: `TempoMapAX.requireMeasuredLocale` refuses a tempo read on a Logic whose language
/// nobody has measured, rather than returning a number parsed by guesswork. The certification
/// system is gone; the refusal is product behaviour a caller sees, so the type moves here.
///
/// Adding a case is a claim that someone measured that locale's tempo surface. It is not a list of
/// languages the product has labels for — `AXLocalePolicy` is that, and it is larger.
enum MeasuredLocale: String, CaseIterable, Sendable {
    case enUS = "en-US"
    case koKR = "ko-KR"
}
