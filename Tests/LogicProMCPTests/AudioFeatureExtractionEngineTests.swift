import AVFoundation
import Foundation
import Testing
@testable import LogicProMCP

/// ADR-012 rollout-1 DSP core — decisive, mutation-sensitive matrix. Fixtures are
/// synthesized in-memory (no committed audio) except two runtime-written temp files that
/// exercise the AVAudioFile decode path and the fifo fast-fail guard.
@Suite("ADR-012 rollout-1 spectral feature extraction engine")
struct AudioFeatureExtractionEngineTests {
    // Anchor: full-scale bin-center sine → band power A²/2 = 0.5 → 10·log10(0.5).
    static let l0 = 10.0 * log10(0.5)              // ≈ -3.0103 dB
    static let calibrationToleranceDb = 0.5        // catches window/one-sided mutations (≥3 dB shift)
    static let fs48 = 48_000.0
    // 1001.95 Hz is an exact 8192-bin center at 48 kHz and lands in the crossover-straddling
    // band (→ 8192/LF window per the pinned configuration), so it exercises the calibrated LF path.
    static let toneHz = 1_001.953_125
    static let frames1s = 48_000

    // MARK: - Synthesis helpers (deterministic; no Date/Random)

    private func sine(_ freq: Double, amplitude: Double = 1.0, sampleRate: Double = fs48, frames: Int = frames1s) -> [Double] {
        (0..<frames).map { amplitude * cos(2.0 * Double.pi * freq * Double($0) / sampleRate) }
    }

    private func nyquist(amplitude: Double = 1.0, frames: Int = frames1s) -> [Double] {
        // cos(2π·(fs/2)·n/fs) = cos(πn) = (−1)^n
        (0..<frames).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    /// Broad hump (60 equal log-spaced tones over ~1.2 octaves, 1600–3600 Hz) with a
    /// lower-amplitude NARROW peak at ~5 kHz. The hump has higher magnitude than the peak,
    /// so a magnitude detector picks the hump; a prominence detector must pick the peak.
    private func humpPlusNarrowPeak(frames: Int = frames1s, sampleRate: Double = fs48) -> [Double] {
        var out = [Double](repeating: 0, count: frames)
        let ncomp = 60
        for j in 0..<ncomp {
            let f = 1_600.0 * pow(3_600.0 / 1_600.0, Double(j) / Double(ncomp - 1))
            for n in 0..<frames { out[n] += 0.12 * cos(2.0 * Double.pi * f * Double(n) / sampleRate) }
        }
        for n in 0..<frames { out[n] += 0.05 * cos(2.0 * Double.pi * 5_001.953_125 * Double(n) / sampleRate) }
        return out
    }

    private func analyze(_ channels: [[Double]], sampleRate: Double = fs48, config: AudioFeatureExtractionEngine.Config = .default, removeDC: Bool = true) -> SpectralAnalysisResult {
        AudioFeatureExtractionEngine.analyze(
            channels: channels,
            sampleRate: sampleRate,
            analysisRef: "analysis-test",
            artifactFingerprint: "fixture",
            config: config,
            removeDC: removeDC
        )
    }

    private func bandDb(_ result: SpectralAnalysisResult, nearHz hz: Double) -> Double {
        result.bands.min(by: { abs($0.centerHz - hz) < abs($1.centerHz - hz) })!.energyDb
    }

    // MARK: - Calibration anchor (matrix: 0-dBFS sine → L0_dbfs; wrong window/one-sided → RED)

    @Test func fullScaleSineAnchorsToL0() {
        let r = analyze([sine(Self.toneHz)])
        #expect(r.complete)
        // The pinned anchor: a full-scale bin-center sine reads L0 (−3.01 dB), NOT 0 dB
        // (amplitude) and NOT −6 dB (missing one-sided doubling) — those mutations shift ≥3 dB.
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < Self.calibrationToleranceDb)
        #expect(abs(AudioFeatureExtractionEngine.l0Dbfs - Self.l0) < 1e-9)
    }

    @Test func dominantBandSitsAtTheToneFrequency() {
        let r = analyze([sine(Self.toneHz)])
        let loudest = r.bands.max(by: { $0.energyDb < $1.energyDb })!
        #expect(abs(loudest.centerHz - 1_016.0) < 60)   // 1/6-oct band nearest ~1 kHz
    }

    // MARK: - DC removal (matrix: sine+DC → 1kHz band present, DC band at floor; drop → RED)

    @Test func dcRemovalKeepsLowestBandAtFloorForSinePlusDC() {
        let sinePlusDC = sine(Self.toneHz).map { $0 + 0.5 }
        let r = analyze([sinePlusDC])                    // removeDC defaults true
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < Self.calibrationToleranceDb)
        // With DC removed, the offset contributes no low-band energy. Deleting the
        // DC-removal block lights band 0 to ~-6 dB → this assertion goes RED.
        #expect(r.bands[0].energyDb < -60)
    }

    // MARK: - DC-only band mapping (matrix: DC-only → energy in lowest band only)

    @Test func dcOnlyMapsToLowestBandOnly() {
        // removeDC:false is a test affordance to OBSERVE where DC energy maps (production
        // always removes DC). A constant input's energy must localize to band 0 and NOT
        // smear into mid/high bands.
        let r = analyze([[Double](repeating: 0.5, count: Self.frames1s)], removeDC: false)
        #expect(r.bands[0].energyDb > -20)
        let highestMidBand = r.bands[5...].map(\.energyDb).max()!
        #expect(highestMidBand < -70)                    // everything above band 0 at floor
    }

    // MARK: - Nyquist (matrix: fs/2 bin scaling, no double)

    @Test func nyquistToneIsNotOneSidedDoubled() {
        let r = analyze([nyquist()])
        // A full-amplitude Nyquist tone has power A²=1 → 0 dB in the top band. Wrongly
        // doubling the Nyquist bin reads +3.01 dB → RED.
        let top = r.bands.last!.energyDb
        #expect(abs(top - 0.0) < Self.calibrationToleranceDb)
    }

    // MARK: - Over-0dBFS (matrix: handled, no clamp)

    @Test func overFullScaleSineIsNotClamped() {
        let r = analyze([sine(Self.toneHz, amplitude: 1.5)])
        #expect(r.complete)
        // 20·log10(1.5) = +3.52 dB above L0 → ~+0.51 dB. A clamp-to-0dBFS would cap it.
        let level = bandDb(r, nearHz: 1_000)
        #expect(abs(level - (Self.l0 + 20.0 * log10(1.5))) < Self.calibrationToleranceDb)
        #expect(level.isFinite)
    }

    // MARK: - Silence (matrix: complete, low confidence → no_safe_recommendation)

    @Test func silenceIsCompleteButLowConfidence() {
        let r = analyze([[Double](repeating: 0, count: Self.frames1s)])
        #expect(r.complete)
        #expect(r.levelConfidence < 0.6)
        guard case .noSafeRecommendation = recommendEQ(r) else {
            Issue.record("silence must yield no_safe_recommendation")
            return
        }
    }

    // MARK: - Prominence not magnitude (matrix: narrow peak detected, broad hump rejected)

    @Test func prominenceDetectsNarrowPeakNotHigherMagnitudeHump() throws {
        let r = analyze([humpPlusNarrowPeak()])
        #expect(r.complete)
        // The hump is HIGHER magnitude than the narrow peak — the premise of the test.
        #expect(bandDb(r, nearHz: 2_500) > bandDb(r, nearHz: 5_000))
        // Prominence detector picks the narrow ~5 kHz peak…
        let nearPeak = r.resonances.contains { abs($0.hz - 5_000) < 300 }
        #expect(nearPeak)
        // …and rejects the broad hump. Deleting the prominence guard reports the hump → RED.
        let inHump = r.resonances.contains { $0.hz > 1_800 && $0.hz < 3_400 }
        #expect(!inHump)
    }

    @Test func narrowResonanceIsResolutionLimitedWithClampedQ() throws {
        let r = analyze([humpPlusNarrowPeak()])
        let peak = try #require(r.resonances.first { abs($0.hz - 5_000) < 300 })
        // A single-band peak cannot resolve its −3 dB width → Q clamped at the resolution
        // ceiling and flagged, never an unbounded value.
        #expect(peak.resolutionLimited)
        #expect(peak.q > 0)
        #expect(peak.gainDb >= 6)
    }

    // MARK: - Channel strategy (energy-average, never sum-to-mono)

    @Test func stereoInPhaseEnergyAveragesToL0() {
        let s = sine(Self.toneHz)
        let r = analyze([s, s])
        #expect(r.channelMode == .stereoEnergyAverage)
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < Self.calibrationToleranceDb)
    }

    @Test func stereoOutOfPhaseDoesNotCancel() {
        // The decisive channel-strategy test: sum-to-mono would cancel L=−R to silence.
        // Per-channel energy-average preserves each channel's energy → band stays at L0.
        let s = sine(Self.toneHz)
        let inverted = s.map { -$0 }
        let r = analyze([s, inverted])
        #expect(r.channelMode == .stereoEnergyAverage)
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < Self.calibrationToleranceDb)
    }

    @Test func multiChannelEnergyAverages() {
        let s = sine(Self.toneHz)
        let r = analyze([s, s, s])
        #expect(r.channelMode == .multiChannelEnergyAverage)
        #expect(r.channelCount == 3)
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < Self.calibrationToleranceDb)
    }

    // MARK: - fs-independent log-band centers (I6)

    @Test func logBandCentersAreIdenticalAcrossSampleRates() {
        let r44 = analyze([sine(Self.toneHz, sampleRate: 44_100, frames: 44_100)], sampleRate: 44_100)
        let r48 = analyze([sine(Self.toneHz, sampleRate: 48_000, frames: 48_000)], sampleRate: 48_000)
        let r96 = analyze([sine(Self.toneHz, sampleRate: 96_000, frames: 96_000)], sampleRate: 96_000)
        #expect(r44.bands.map(\.centerHz) == r48.bands.map(\.centerHz))
        #expect(r48.bands.map(\.centerHz) == r96.bands.map(\.centerHz))
        // The same tone lands in the same band at the same calibrated level at every fs.
        for r in [r44, r48, r96] {
            #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < 0.7)
        }
    }

    // MARK: - I4b fail-closed

    @Test func nonFiniteInputFailsClosed() throws {
        var s = sine(Self.toneHz)
        s[1_000] = Double.nan
        s[2_000] = Double.infinity
        let r = analyze([s])
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "non_finite_input")
        #expect(r.bands.isEmpty)
        guard case .noSafeRecommendation = recommendEQ(r) else {
            Issue.record("non-finite input must not yield a recommendation")
            return
        }
    }

    @Test func tooShortInputFailsClosed() throws {
        let r = analyze([sine(Self.toneHz, frames: 4_096)])   // < 8192 minimum window
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_short")
        #expect(r.bands.isEmpty)
    }

    // MARK: - Computed centroid + peaks (computed, not placeholders)

    @Test func centroidAndPeaksAreComputed() throws {
        let r = analyze([sine(Self.toneHz)])
        let centroid = try #require(r.spectralCentroidHz)
        #expect(centroid > 500 && centroid < 2_000)         // near the 1 kHz tone
        #expect(!r.frequencyPeaks.isEmpty)
        let topPeak = try #require(r.frequencyPeaks.first)
        #expect(abs(topPeak.frequencyHz - 1_016.0) < 80)
    }

    // MARK: - Determinism harness (I1)

    private func withinI1Gate(_ a: [SpectralBand], _ b: [SpectralBand], relTol: Double = 1e-4, floorDbfs: Double = -80, absEps: Double = 1e-9) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            let pa = pow(10.0, a[i].energyDb / 10.0)
            let pb = pow(10.0, b[i].energyDb / 10.0)
            if a[i].energyDb >= floorDbfs || b[i].energyDb >= floorDbfs {
                if abs(pa - pb) / max(pa, pb) > relTol { return false }
            } else if abs(pa - pb) > absEps {
                return false
            }
        }
        return true
    }

    @Test func determinismDoubleRunWithinGateAndPerturbDiffers() {
        let fixture = [zip(zip(sine(100.181_884_765_625), sine(Self.toneHz)), sine(5_001.953_125))
            .map { 0.5 * $0.0.0 + 0.3 * $0.0.1 + 0.2 * $0.1 }]
        let a = analyze(fixture)
        let b = analyze(fixture)                            // identical input + config
        #expect(withinI1Gate(a.bands, b.bands))

        var perturbed = AudioFeatureExtractionEngine.Config.default
        perturbed.crossoverHz = 0                           // forces LF bands onto the 2048 window
        let c = analyze(fixture, config: perturbed)
        #expect(!withinI1Gate(a.bands, c.bands))            // harness would catch a real change
    }

    // MARK: - I2 / I7 structural honesty (recommendation-only)

    @Test func recommendationSchemaCarriesNoApplyOrVerifyKeys() throws {
        let outcome = recommendEQ(
            SpectralAnalysisResult(
                analysisRef: "a", bands: [], resonances: [SpectralResonance(hz: 800, gainDb: 4, q: 3)],
                classification: .vocal, levelConfidence: 0.9, complete: true, partialReason: nil
            )
        )
        guard case .recommendation(let bands) = outcome else {
            Issue.record("expected a recommendation")
            return
        }
        let json = String(decoding: try JSONEncoder().encode(bands), as: UTF8.self)
        #expect(!json.contains("applied"))
        #expect(!json.contains("verified"))
        #expect(!json.contains("adjusted"))
        #expect(json.contains("centerHz"))
        #expect(json.contains("reason"))
    }

    // MARK: - File entry: native decode, special-file guard, path safety (safe-input contract)

    private func writeWAV(_ name: String, sampleRate: Double, samples: [Double]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adr012-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ch = buffer.floatChannelData![0]
        for i in 0..<samples.count { ch[i] = Float(samples[i]) }
        try file.write(from: buffer)
        return url
    }

    @Test func analyzeFileDecodesNativeWAVAndComputesFeatures() throws {
        let url = try writeWAV("tone.wav", sampleRate: Self.fs48, samples: sine(Self.toneHz))
        let r = try AudioFeatureExtractionEngine.analyzeFile(path: url.path, analysisRef: "file", artifactFingerprint: "wav")
        #expect(r.complete)
        #expect(r.channelCount == 1)
        #expect(r.sampleRate == Self.fs48)
        // The decode-path fixture asserts peak LOCATION + a loose level, not the tight
        // golden (decode drift is acknowledged).
        let loudest = r.bands.max(by: { $0.energyDb < $1.energyDb })!
        #expect(abs(loudest.centerHz - 1_016.0) < 80)
        #expect(abs(bandDb(r, nearHz: 1_000) - Self.l0) < 1.0)
        #expect(try #require(r.spectralCentroidHz) > 0)
    }

    @Test func analyzeFileRejectsFifoFastFail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adr012-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("pipe.wav")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        do {
            _ = try AudioFeatureExtractionEngine.analyzeFile(path: fifo.path, analysisRef: "f", artifactFingerprint: "x")
            Issue.record("fifo must fail closed, not block the decoder")
        } catch let error as AudioFeatureExtractionEngine.FeatureExtractionError {
            guard case .specialFile = error else {
                Issue.record("expected specialFile, got \(error)")
                return
            }
        }
    }

    @Test func analyzeFileRejectsUnsafePath() throws {
        do {
            _ = try AudioFeatureExtractionEngine.analyzeFile(path: "relative.wav", analysisRef: "f", artifactFingerprint: "x")
            Issue.record("relative path must be rejected by the shared validator")
        } catch is AudioAnalyzer.AnalysisError {
            // expected — reuses AudioAnalyzer.validatedURL
        }
    }

    // MARK: - Bounded streaming (blocker 1): multi-chunk ≡ single-chunk ≡ in-memory core

    private func streamMultiTone(frames: Int) -> [Double] {
        let low = sine(100.181_884_765_625, amplitude: 0.5, frames: frames)
        let mid = sine(Self.toneHz, amplitude: 0.3, frames: frames)
        let high = sine(5_001.953_125, amplitude: 0.2, frames: frames)
        var out = [Double](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = low[i] + mid[i] + high[i] }
        return out
    }

    private func streamAnalyze(_ channels: [[Double]], declared: Int64, chunkFrames: Int, deliver: Int? = nil, throwAfter: Int? = nil, maxFrames: Int64? = nil, maxDuration: Double? = nil) -> SpectralAnalysisResult {
        let feeder = ChunkFeeder(channels: channels, deliverFrames: deliver ?? channels[0].count, throwAfter: throwAfter)
        return AudioFeatureExtractionEngine.analyzeStreaming(
            declaredFrameLength: declared,
            sampleRate: Self.fs48,
            channelCount: channels.count,
            analysisRef: "stream",
            artifactFingerprint: "fixture",
            chunkFrames: chunkFrames,
            maxDurationSeconds: maxDuration,
            maxDecodedFrames: maxFrames,
            reset: { feeder.reset() },
            nextChunk: { try feeder.next($0) }
        )
    }

    // Variant that exposes the feeder so a test can compare frames INGESTED (from the
    // fail-closed result's frame count) against frames DELIVERED (tracked by the feeder).
    private func runStreaming(_ channels: [[Double]], declared: Int64, deliver: Int? = nil, pass2Deliver: Int? = nil, maxFrames: Int64? = nil, maxDuration: Double? = nil, chunkFrames: Int = 64_000) -> (result: SpectralAnalysisResult, feeder: ChunkFeeder) {
        let feeder = ChunkFeeder(channels: channels, deliverFrames: deliver ?? channels[0].count, pass2DeliverFrames: pass2Deliver)
        let r = AudioFeatureExtractionEngine.analyzeStreaming(
            declaredFrameLength: declared, sampleRate: Self.fs48, channelCount: channels.count,
            analysisRef: "stream", artifactFingerprint: "fixture", chunkFrames: chunkFrames,
            maxDurationSeconds: maxDuration, maxDecodedFrames: maxFrames,
            reset: { feeder.reset() }, nextChunk: { try feeder.next($0) }
        )
        return (r, feeder)
    }

    // Frames actually ingested at fail time: the fail-closed result carries the pre-rejection
    // count as its duration, so frames == durationSeconds * sampleRate.
    private func ingestedFrames(_ r: SpectralAnalysisResult) -> Int {
        Int((r.durationSeconds * Self.fs48).rounded())
    }

    @Test func streamingMultiChunkEqualsSingleChunkAndCore() {
        let samples = streamMultiTone(frames: 200_000)          // > 3 chunks of 64k frames
        let core = analyze([samples])                           // in-memory whole-array path
        let single = streamAnalyze([samples], declared: 200_000, chunkFrames: 10_000_000)
        let multi = streamAnalyze([samples], declared: 200_000, chunkFrames: 64_000)
        #expect(multi.complete)
        #expect(single.complete)
        #expect(multi.windowsAnalyzed > 0)
        // Chunk boundaries must not change the result: multi-chunk == single-chunk == core.
        #expect(withinI1Gate(multi.bands, single.bands))
        #expect(withinI1Gate(multi.bands, core.bands))
    }

    // MARK: - Early EOF / truncation (blocker 3): never complete:true

    @Test func truncatedDeliveryFailsClosed() throws {
        let samples = streamMultiTone(frames: 200_000)
        // Declares 200k frames but only 120k are delivered → truncated, never complete.
        let r = streamAnalyze([samples], declared: 200_000, chunkFrames: 64_000, deliver: 120_000)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "decode_truncated")
        #expect(r.bands.isEmpty)
        guard case .noSafeRecommendation = recommendEQ(r) else {
            Issue.record("truncated analysis must not yield a recommendation")
            return
        }
    }

    @Test func readErrorMidStreamFailsClosed() throws {
        let samples = streamMultiTone(frames: 200_000)
        let r = streamAnalyze([samples], declared: 200_000, chunkFrames: 64_000, throwAfter: 100_000)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "decode_truncated")
    }

    // MARK: - Compute caps (blocker: enforce AnalysisPolicy limits)

    @Test func declaredLengthOverCapFailsClosed() throws {
        let samples = streamMultiTone(frames: 140_000)
        // Header declares 300k frames — above the 150k cap — so analysis must not start.
        let r = streamAnalyze([samples], declared: 300_000, chunkFrames: 64_000, deliver: 140_000, maxFrames: 150_000)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_long")
        #expect(r.bands.isEmpty)
    }

    @Test func declaredDurationOverCapFailsClosed() throws {
        let samples = streamMultiTone(frames: 100_000)
        // 100k frames @ 48 kHz ≈ 2.08 s: under a generous frames cap but over a 1 s duration
        // cap, so the duration branch of the declared-length guard must fail it closed.
        let r = streamAnalyze([samples], declared: 100_000, chunkFrames: 64_000, maxFrames: 10_000_000, maxDuration: 1.0)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_long")
        #expect(r.bands.isEmpty)
        guard case .noSafeRecommendation = recommendEQ(r) else {
            Issue.record("over-duration analysis must not yield a recommendation")
            return
        }
    }

    @Test func lyingHeaderDeliveryOverCapFailsClosedInLoop() throws {
        let samples = streamMultiTone(frames: 300_000)
        // Header declares 100k (under cap) but delivers 300k (over the 150k frame cap). The
        // in-loop guard must fail closed WITHOUT accumulating the over-cap chunk.
        let (r, feeder) = runStreaming([samples], declared: 100_000, deliver: 300_000, maxFrames: 150_000)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_long")
        #expect(r.bands.isEmpty)
        // Zero excess: fewer frames were accumulated than the seam delivered, so the chunk
        // that would exceed the cap never entered the mean.
        #expect(ingestedFrames(r) < feeder.deliveredByPass[0])
        guard case .noSafeRecommendation = recommendEQ(r) else {
            Issue.record("over-cap analysis must not yield a recommendation")
            return
        }
    }

    @Test func fileSizeCapFailsClosed() throws {
        let url = try writeWAV("sized.wav", sampleRate: Self.fs48, samples: sine(Self.toneHz))
        var policy = AudioAnalyzer.AnalysisPolicy.default
        policy.maximumInputFileSizeBytes = 1_024      // the real WAV is far larger than 1 KiB
        let r = try AudioFeatureExtractionEngine.analyzeFile(path: url.path, analysisRef: "sz", artifactFingerprint: "x", policy: policy)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_large")
        #expect(r.bands.isEmpty)
    }

    @Test func deliveredDurationOverCapFailsClosedInLoop() throws {
        let samples = streamMultiTone(frames: 200_000)
        // Declared ~0.83 s (under the 1 s cap) but delivery is 200k frames ≈ 4.2 s — over the
        // duration cap while well under a generous frame cap (duration binds first). The chunk
        // pushing past 1 s must not be accumulated.
        let (r, feeder) = runStreaming([samples], declared: 40_000, deliver: 200_000, maxFrames: 10_000_000, maxDuration: 1.0)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "input_too_long")
        #expect(r.bands.isEmpty)
        #expect(ingestedFrames(r) < feeder.deliveredByPass[0])
    }

    @Test func passTwoOverDeliveryStopsBounded() throws {
        let samples = streamMultiTone(frames: 300_000)
        // Pass 1 delivers a consistent 100k; pass 2 lies and offers 300k. The pass-2 bound
        // must reject the over-count chunk BEFORE any of its frames reach the DSP.
        let (r, feeder) = runStreaming([samples], declared: 100_000, deliver: 100_000, pass2Deliver: 300_000)
        #expect(!r.complete)
        let reason = try #require(r.partialReason)
        #expect(reason == "decode_truncated")
        #expect(feeder.deliveredByPass.count >= 2)
        // Zero excess into pass 2's DSP: fewer frames ingested than pass 2 delivered.
        #expect(ingestedFrames(r) < feeder.deliveredByPass[1])
    }

    @Test func fileSizeCapBoundary() throws {
        let url = try writeWAV("fsb.wav", sampleRate: Self.fs48, samples: sine(Self.toneHz))
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        var atCap = AudioAnalyzer.AnalysisPolicy.default
        atCap.maximumInputFileSizeBytes = Int64(size)              // exactly at the cap → analyzes
        let rAt = try AudioFeatureExtractionEngine.analyzeFile(path: url.path, analysisRef: "b", artifactFingerprint: "x", policy: atCap)
        #expect(rAt.complete)
        var over = AudioAnalyzer.AnalysisPolicy.default
        over.maximumInputFileSizeBytes = Int64(size - 1)           // one byte under → fails closed
        let rOver = try AudioFeatureExtractionEngine.analyzeFile(path: url.path, analysisRef: "b", artifactFingerprint: "x", policy: over)
        #expect(!rOver.complete)
        #expect(try #require(rOver.partialReason) == "input_too_large")
    }

    @Test func declaredFramesCapBoundary() throws {
        let samples = streamMultiTone(frames: 100_000)
        let rAt = streamAnalyze([samples], declared: 100_000, chunkFrames: 64_000, maxFrames: 100_000, maxDuration: 3_600)
        #expect(rAt.complete)                                      // declared == frame cap → analyzes
        let rOver = streamAnalyze([samples], declared: 100_001, chunkFrames: 64_000, deliver: 100_000, maxFrames: 100_000, maxDuration: 3_600)
        #expect(!rOver.complete)                                   // one frame over → fails closed
        #expect(try #require(rOver.partialReason) == "input_too_long")
    }

    @Test func declaredDurationCapBoundary() throws {
        let samples = streamMultiTone(frames: 48_001)
        let rAt = streamAnalyze([samples], declared: 48_000, chunkFrames: 64_000, deliver: 48_000, maxFrames: 10_000_000, maxDuration: 1.0)
        #expect(rAt.complete)                                      // 48000/48000 == 1.0 s → analyzes
        let rOver = streamAnalyze([samples], declared: 48_001, chunkFrames: 64_000, deliver: 48_001, maxFrames: 10_000_000, maxDuration: 1.0)
        #expect(!rOver.complete)                                   // one frame over 1 s → fails closed
        #expect(try #require(rOver.partialReason) == "input_too_long")
    }

    // MARK: - TOCTOU identity binding (blocker 2)

    @Test func pathIdentityMismatchFailsClosed() throws {
        let url = try writeWAV("id.wav", sampleRate: Self.fs48, samples: sine(Self.toneHz))
        // A probe reporting a different inode than the held descriptor's models a post-open
        // path swap → analysis must fail closed rather than decode whatever the path now points at.
        let bogus = AudioFeatureExtractionEngine.IdentityProbe { _ in (dev: -1, ino: 0) }
        do {
            _ = try AudioFeatureExtractionEngine.analyzeFile(path: url.path, analysisRef: "id", artifactFingerprint: "x", identityProbe: bogus)
            Issue.record("identity mismatch must fail closed")
        } catch let error as AudioFeatureExtractionEngine.FeatureExtractionError {
            guard case .pathIdentityChanged = error else {
                Issue.record("expected pathIdentityChanged, got \(error)")
                return
            }
        }
    }

    // MARK: - Codable compatibility with legacy resonances (blocker 5)

    @Test func legacyResonanceArrayDecodesWithDefaults() throws {
        // Legacy stored analysis: NON-EMPTY resonances WITHOUT resolutionLimited, and none of
        // the rollout-1 fields. Must decode with defaults rather than throwing.
        let json = """
        {"analysisRef":"legacy-1","bands":[{"centerHz":1000,"energyDb":-3}],\
        "resonances":[{"hz":3200,"gainDb":5,"q":2},{"hz":800,"gainDb":4,"q":1.5}],\
        "classification":"vocal","confidence":0.8,"complete":true,"partialReason":null}
        """
        let decoded = try JSONDecoder().decode(SpectralAnalysisResult.self, from: Data(json.utf8))
        #expect(decoded.resonances.count == 2)
        let first = try #require(decoded.resonances.first)
        #expect(first.hz == 3200)
        #expect(!first.resolutionLimited)            // absent field → default false
        #expect(decoded.artifactFingerprint == "")   // absent rollout-1 field → default
        #expect(decoded.sampleRate == 0)
        #expect(decoded.frequencyPeaks.isEmpty)
    }

    @Test func newFormatResonanceRoundTrips() throws {
        let original = SpectralAnalysisResult(
            analysisRef: "rt-1",
            bands: [SpectralBand(centerHz: 1_000, energyDb: -3)],
            resonances: [SpectralResonance(hz: 5_120, gainDb: 9, q: 12, resolutionLimited: true)],
            classification: .drums, levelConfidence: 0.7, complete: true, partialReason: nil,
            artifactFingerprint: "fp", sampleRate: 48_000, channelCount: 2, durationSeconds: 1.0,
            windowsAnalyzed: 42, channelMode: .stereoEnergyAverage,
            spectralCentroidHz: 1_234.5, frequencyPeaks: [AudioAnalyzer.FrequencyPeak(frequencyHz: 5_120, magnitude: 0.5)]
        )
        let decoded = try JSONDecoder().decode(SpectralAnalysisResult.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let res = try #require(decoded.resonances.first)
        #expect(res.resolutionLimited)
        #expect(res.hz == 5_120)
    }
}

/// Deterministic chunk feeder for the streaming core: delivers `deliverFrames` frames of the
/// backing channels in `next`-sized blocks (fewer than declared = truncation), and can throw
/// mid-stream to model a decode error. No randomness or wall-clock — reset re-delivers.
private final class ChunkFeeder {
    private let channels: [[Double]]
    private let deliverFrames: Int
    private let pass2DeliverFrames: Int?
    private let throwAfter: Int?
    private var pos = 0
    private var passIndex = -1
    // Frames actually delivered per streaming pass (index 0 = pass 1). Lets a test prove the
    // pass-2 loop stops bounded instead of streaming an over-delivering source to EOF.
    private(set) var deliveredByPass: [Int] = []

    struct ReadFault: Error {}

    init(channels: [[Double]], deliverFrames: Int, pass2DeliverFrames: Int? = nil, throwAfter: Int? = nil) {
        self.channels = channels
        self.deliverFrames = deliverFrames
        self.pass2DeliverFrames = pass2DeliverFrames
        self.throwAfter = throwAfter
    }

    func reset() {
        pos = 0
        passIndex += 1
        deliveredByPass.append(0)
    }

    func next(_ maxFrames: Int) throws -> [[Double]] {
        if let throwAfter, pos >= throwAfter { throw ReadFault() }
        let cap = (passIndex >= 1 ? (pass2DeliverFrames ?? deliverFrames) : deliverFrames)
        let end = min(min(cap, channels[0].count), pos + max(1, maxFrames))
        if end <= pos { return channels.map { _ in [Double]() } }
        let block = channels.map { Array($0[pos..<end]) }
        deliveredByPass[passIndex] += end - pos
        pos = end
        return block
    }
}

/// #300 — a band whose edges enclose no FFT bin does not report the floor as a reading.
///
/// Measured 2026-08-28 at 44.1 kHz with the default grid: the bands at 25.198 and 40 Hz come back
/// at exactly `floorDbfs` for every signal tried, white noise included. The log-spaced bands are
/// about 3 Hz wide down there and the 8192-point window resolves 5.383 Hz, so no bin lands inside
/// them. `-80 dB` in that position reads as "this region is silent", which is a false statement
/// about the audio rather than a small one about the grid.
@Suite("Issue300UnmeasurableBands")
struct Issue300UnmeasurableBandsTests {

    @Test("the grid names exactly the bands it cannot measure at 44.1 kHz")
    func maskMatchesTheMeasurement() {
        let grid = AudioFeatureExtractionEngine.makeGrid()
        let mask = AudioFeatureExtractionEngine.measurableBands(grid: grid, sampleRate: 44_100)

        #expect(mask.count == grid.centers.count)
        let unmeasurable = zip(grid.centers, mask).filter { !$0.1 }.map { ($0.0 * 1000).rounded() / 1000 }
        // Derived from the code and confirmed against the live analyser's output, not asserted from
        // one side only: `analyze_spectrum` reports `measured: false` for these two and no others.
        #expect(unmeasurable == [20.0, 25.198, 40.0], "got \(unmeasurable)")
    }

    @Test("an edge band that accumulates out-of-range content is not reported as a reading")
    func accumulatorBandsAreNotReadings() throws {
        let grid = AudioFeatureExtractionEngine.makeGrid()
        // The mapping is TOTAL and stays that way: everything below the first edge lands in band 0.
        // Dropping that content was tried and reverted — `dcOnlyMapsToLowestBandOnly` and
        // `nyquistToneIsNotOneSidedDoubled` pin calibration properties that need those bins
        // accounted somewhere, and moving where energy goes to fix how a band is REPORTED is a
        // wider change than the defect.
        #expect(grid.bandIndex(forFrequency: 5) == 0)
        #expect(grid.bandIndex(forFrequency: 25_000) == grid.centers.count - 1)

        // What changes is the reporting. Band 0's own edges enclose no bin at 44.1 kHz, so its
        // energy is the sub-18.9 Hz sum and not a reading of the 20 Hz band — and it says so.
        let mask = AudioFeatureExtractionEngine.measurableBands(grid: grid, sampleRate: 44_100)
        let firstBand = try #require(mask.first)
        #expect(!firstBand, "band 0 still claims a reading its own range cannot support")
    }

    @Test("a finer window measures bands the default one cannot")
    func theMaskFollowsTheWindow() {
        // The negative control for the mask: it has to depend on resolution, or it is just a
        // hard-coded pair of frequencies.
        //
        // Counted BELOW 100 Hz, and the first version of this case did not, which is why it failed:
        // a quarter sample rate gives the same window four times the low-frequency resolution AND
        // drops Nyquist to 5512 Hz, so every band above that becomes unmeasurable and the total
        // goes UP (9 against 2). The mask is right about both ends; the assertion was only looking
        // at one and calling the sum a resolution.
        let grid = AudioFeatureExtractionEngine.makeGrid()
        func unmeasurableBelow100Hz(_ rate: Double) -> Int {
            zip(grid.centers, AudioFeatureExtractionEngine.measurableBands(grid: grid, sampleRate: rate))
                .filter { $0.0 < 100 && !$0.1 }.count
        }
        #expect(unmeasurableBelow100Hz(44_100) == 3)
        #expect(unmeasurableBelow100Hz(11_025) < unmeasurableBelow100Hz(44_100),
                "four times the low-frequency resolution measured no more bands")

        // And the other end, so the Nyquist half is asserted rather than merely explained.
        //
        // Keyed on the LOWER EDGE, not the centre. A band whose centre sits above Nyquist can still
        // enclose a bin when its lower edge is below it — that band straddles Nyquist and is
        // genuinely measurable. Filtering by centre called it a defect, which is the third time
        // this control has been sharper than its first phrasing.
        let nyquist = 11_025.0 / 2
        let mask11k = AudioFeatureExtractionEngine.measurableBands(grid: grid, sampleRate: 11_025)
        let whollyAbove = (0..<grid.centers.count).filter { grid.edges[$0] > nyquist }
        #expect(!whollyAbove.isEmpty)
        #expect(whollyAbove.allSatisfy { !mask11k[$0] },
                "a band whose lower edge is above Nyquist was called measurable")
    }
}

/// #300 — the accumulator bands are excluded from peaks and the centroid too, not only from
/// resonance candidates.
///
/// Found by auditing this issue's acceptance criteria AFTER the surface was promoted, which is the
/// wrong order: `frequency_peaks` published band 0 at 20 Hz — the sub-18.9 Hz sum — while the
/// resonance detector had already been taught to skip it. The same artifact was reachable through a
/// different field.
@Suite("Issue300AccumulatorsAreNotPeaks")
struct Issue300AccumulatorsAreNotPeaksTests {

    @Test("no reported peak is a band the analyser could not measure")
    func peaksExcludeUnmeasurableBands() throws {
        // Pink-ish: real energy below the grid, which is what fills the accumulator. A flat signal
        // would not exercise this at all.
        var b = [Double](repeating: 0, count: 7)
        var samples = [Double]()
        var state = UInt64(7)
        for _ in 0..<(44_100 * 3) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let w = Double(Int64(bitPattern: state >> 11)) / Double(Int64.max) * 1e-8
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.0168980
            samples.append((b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362) * 0.11)
            b[6] = w * 0.115926
        }
        let peak = samples.map(abs).max() ?? 1
        samples = samples.map { $0 / peak * 0.7 }

        let result = AudioFeatureExtractionEngine.analyze(
            channels: [samples], sampleRate: 44_100,
            analysisRef: "peaks-1", artifactFingerprint: "x")

        let unmeasurable = Set(result.bands.filter { !$0.measured }.map { $0.centerHz })
        #expect(!unmeasurable.isEmpty, "the fixture did not produce an unmeasurable band")
        for peak in result.frequencyPeaks {
            #expect(!unmeasurable.contains(peak.frequencyHz),
                    "\(peak.frequencyHz) Hz is reported as a peak and could not be measured")
        }
    }
}
