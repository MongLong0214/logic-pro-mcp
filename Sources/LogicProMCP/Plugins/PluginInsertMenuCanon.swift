import Foundation

/// What the plug-in insert menu is KNOWN to contain, as data the insert spec is built from.
///
/// Three facts, each from a different measured source, and nothing typed from memory:
/// - the root categories: the open insert menu read on Logic 12.3 (6674) in all ten locales,
///   docs/observations/evidence/2026-09-26-<locale>-nbsp-labels-as-drawn.json. They are English in
///   every one, `Delay`, `Pitch` and `Reverb` at items 9, 18 and 19 of each root menu.
/// - the plug-in names: Logic's own DefaultPluginMapping.plist, the canon source `plugin_names`
///   (locale `-`, 242 entries). A name is listed here only when its digest is a row of
///   docs/canon/index/plugin_names.tsv. `Quantec Room Simulator` and `ChromaGlow` are catalog
///   entries with no such row, so they are not here and refuse.
/// - the format leaf: AXLocalePolicy.pluginFormatStereo, unchanged.
///
/// Which category holds which plug-in is the stock catalog's. That mapping is not in the canon, so
/// it is the one part of a menu path that only a live walk can confirm; a wrong one ends in
/// `no_path_segment_matched`, never in a different plug-in.
enum PluginInsertMenuCanon {
    static let measuredRootCategories: Set<String> = [
        "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging",
        "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility",
    ]

    static let measuredPluginNames: Set<String> = [
        "Channel EQ",
        "Linear Phase EQ",
        "Match EQ",
        "Single Band EQ",
        "Vintage Console EQ",
        "Vintage Graphic EQ",
        "Vintage Tube EQ",
        "Adaptive Limiter",
        "Compressor",
        "DeEsser 2",
        "Enveloper",
        "Expander",
        "Limiter",
        "Multipressor",
        "Noise Gate",
        "ChromaVerb",
        "SilverVerb",
        "Space Designer",
        "Delay Designer",
        "Echo",
        "Sample Delay",
        "Stereo Delay",
        "Tape Delay",
        "Chorus",
        "Ensemble",
        "Flanger",
        "Microphaser",
        "Modulation Delay",
        "Phaser",
        "Ringshifter",
        "Rotor Cabinet",
        "Scanner Vibrato",
        "Spreader",
        "Tremolo",
        "Bitcrusher",
        "Clip Distortion",
        "Distortion",
        "Distortion II",
        "Overdrive",
        "Phase Distortion",
        "AutoFilter",
        "EVOC 20 Filterbank",
        "Fuzz-Wah",
        "Spectral Gate",
        "Direction Mixer",
        "Stereo Spread",
        "Pitch Correction",
        "Pitch Shifter",
        "Vocal Transformer",
        "Gain",
        "I/O",
        "Test Oscillator",
        "Correlation Meter",
        "Level Meter",
        "Loudness Meter",
        "MultiMeter",
        "Tuner",
        "Exciter",
        "SubBass",
        "Beat Breaker",
        "Phat FX",
        "Remix FX",
        "Step FX",
        "Amp Designer",
        "Bass Amp Designer",
        "Pedalboard",
    ]

    /// Every locale the root-category reading covers.
    static let categoryLocales = [
        "en-US", "ko-KR", "ja-JP", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR", "zh-CN", "zh-TW",
    ]
}
