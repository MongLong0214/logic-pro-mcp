func isReferenceCurrent(
    _ ref: FlexPitchNoteReference,
    currentAnalysisGeneration: UInt64
) -> Bool {
    ref.analysisGeneration == currentAnalysisGeneration
}

func staleReferences(
    _ refs: [FlexPitchNoteReference],
    currentAnalysisGeneration: UInt64
) -> [FlexPitchNoteReference] {
    refs.filter { !isReferenceCurrent($0, currentAnalysisGeneration: currentAnalysisGeneration) }
}
