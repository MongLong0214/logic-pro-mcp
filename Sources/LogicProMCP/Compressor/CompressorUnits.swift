enum CompressorUnit: Sendable {
    case decibels
    case milliseconds
    case ratio
    case percent
    case enumerated
    case boolean
}

func displayToNormalized(
    _ value: Double,
    unit _: CompressorUnit,
    range: ClosedRange<Double>
) -> Double {
    let width = range.upperBound - range.lowerBound
    guard width != 0 else { return 0 }
    return (value - range.lowerBound) / width
}

func normalizedToDisplay(
    _ value: Double,
    unit _: CompressorUnit,
    range: ClosedRange<Double>
) -> Double {
    range.lowerBound + value * (range.upperBound - range.lowerBound)
}
