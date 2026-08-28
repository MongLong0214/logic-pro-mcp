import Accelerate
import AVFoundation
import Foundation

/// ADR-012 rollout-1 DSP core (#300). Read-only spectral feature extraction over safe audio
/// paths / synthesized channel data. Produces a `SpectralAnalysisResult` — never mutates
/// Logic or any file, never taps live audio. Pure LANE-P (headless, CI-testable).
///
/// Determinism (I1): no `Date`/random, serial fixed-order FP reduction (no
/// `concurrentPerform` accumulation). Deterministic on a fixed OS+arch+binary within the
/// rel-power + floor gate — NOT claimed bit-identical across microarchitectures.
enum AudioFeatureExtractionEngine {
    /// Pinned DSP configuration (ADR-012 pinned DSP configuration). Mutable only to let the determinism harness
    /// perturb it and prove the harness would catch a real change; production always uses
    /// `.default`.
    struct Config: Equatable, Sendable {
        var bandsPerOctave: Int = 6
        var fMinHz: Double = 20
        var fMaxHz: Double = 20_000
        var crossoverHz: Double = 1_000          // F_X: <F_X uses the large (LF) window
        var floorDbfs: Double = -80
        var windowLarge: Int = 8_192             // below/straddling crossover (freq-resolution)
        var windowSmall: Int = 2_048             // at/above crossover (variance/time averaging)
        var overlap: Double = 0.75               // 75% -> hop = N/4
        var prominenceMinDb: Double = 6          // P_min
        var resonanceHalfWindowOctaves: Double = 0.5   // W_b (median local-baseline half width)
        var maxResonanceWidthOctaves: Double = 1.0     // reject broader-than-this as a hump

        static let `default` = Config()
    }

    enum FeatureExtractionError: Error, Equatable, Sendable {
        case specialFile(String)
        case unreadable(String)
        case unsupportedFormat(String)
        case decode(String)
        // The path stopped resolving to the descriptor's bound inode between open and use.
        case pathIdentityChanged
    }

    /// Injectable path-identity probe so the descriptor↔path binding check is testable
    /// without racing the real filesystem. Production reads the live inode identity.
    struct IdentityProbe: Sendable {
        var statIdentity: @Sendable (String) throws -> (dev: Int64, ino: UInt64)

        static let production = IdentityProbe { path in
            var info = stat()
            guard stat(path, &info) == 0 else {
                throw FeatureExtractionError.unreadable("stat failed: \(String(cString: strerror(errno)))")
            }
            return (Int64(info.st_dev), UInt64(info.st_ino))
        }
    }

    /// Full-scale (0 dBFS) bin-centered sine anchor: under the one-sided ENBW-normalized
    /// band power a full-scale sine's band sum is A²/2 = 0.5 → 10·log10(0.5). Pinned so a
    /// wrong window/one-sided normalization shifts the calibration test by ≥3 dB.
    static let l0Dbfs = 10.0 * log10(0.5)

    static let minAnalyzableFrames = Config.default.windowLarge

    // MARK: - Log-frequency band grid (fs-independent — I6)

    struct BandGrid: Equatable, Sendable {
        let centers: [Double]
        let edges: [Double]   // count == centers.count + 1, ascending

        /// Bin frequency → band index. Sub-`fMin` energy (incl. DC) clamps into band 0 and
        /// super-`fMax` energy (incl. a Nyquist tone) clamps into the top band, so no energy
        /// is silently dropped.
        /// The band this frequency belongs to. Total: everything below the first edge lands in band
        /// 0 and everything above the last lands in the top band.
        ///
        /// That makes the edge bands ACCUMULATORS — band 0's energy is the sum of all sub-18.9 Hz
        /// content, DC included, and not the 20 Hz band's. Dropping the out-of-range content was
        /// tried and reverted: `dcOnlyMapsToLowestBandOnly` and `nyquistToneIsNotOneSidedDoubled`
        /// pin calibration properties that need those bins accounted somewhere, and changing where
        /// the energy goes to fix how a band is REPORTED is a wider change than the defect.
        ///
        /// The reporting is fixed instead — see `measurableBands`, which no longer exempts the edge
        /// bands, so band 0 is marked as not a reading of its own range.
        func bandIndex(forFrequency f: Double) -> Int {
            if f < edges[0] { return 0 }
            if f >= edges[edges.count - 1] { return centers.count - 1 }
            var lo = 0
            var hi = edges.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if edges[mid] <= f { lo = mid } else { hi = mid }
            }
            return min(lo, centers.count - 1)
        }
    }

    static func makeGrid(_ config: Config = .default) -> BandGrid {
        let bpo = Double(config.bandsPerOctave)
        let m = Int((bpo * log2(config.fMaxHz / config.fMinHz)).rounded(.down))
        var centers = [Double]()
        centers.reserveCapacity(m + 1)
        for i in 0...m {
            centers.append(config.fMinHz * pow(2.0, Double(i) / bpo))
        }
        let halfStep = pow(2.0, 0.5 / bpo)
        var edges = [Double]()
        edges.reserveCapacity(centers.count + 1)
        edges.append(centers[0] / halfStep)
        for i in 0..<(centers.count - 1) {
            edges.append((centers[i] * centers[i + 1]).squareRoot())
        }
        edges.append(centers[centers.count - 1] * halfStep)
        return BandGrid(centers: centers, edges: edges)
    }

    // MARK: - Public core entry (in-memory, deterministic, no I/O)

    /// Decoded per-channel PCM (native format, no SRC) → analysis. `removeDC` is a test
    /// affordance to demonstrate DC band mapping; production/file path always removes DC.
    static func analyze(
        channels: [[Double]],
        sampleRate: Double,
        analysisRef: String,
        artifactFingerprint: String,
        config: Config = .default,
        removeDC: Bool = true
    ) -> SpectralAnalysisResult {
        let channelCount = channels.count
        let mode = ChannelMode(channelCount: channelCount)
        let frameCount = channels.map(\.count).min() ?? 0
        let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0

        func failClosed(_ reason: String) -> SpectralAnalysisResult {
            SpectralAnalysisResult(
                analysisRef: analysisRef,
                bands: [],
                resonances: [],
                classification: .unknown,
                confidence: 0,
                complete: false,
                partialReason: reason,
                artifactFingerprint: artifactFingerprint,
                sampleRate: sampleRate,
                channelCount: channelCount,
                durationSeconds: duration,
                windowsAnalyzed: 0,
                channelMode: mode,
                spectralCentroidHz: nil,
                frequencyPeaks: []
            )
        }

        // I4b: fail closed on non-finite input BEFORE any FFT touches it.
        for channel in channels {
            for sample in channel where !sample.isFinite {
                return failClosed("non_finite_input")
            }
        }
        // I4b: too short to fill even one large window.
        guard channelCount > 0, sampleRate > 0, frameCount >= minAnalyzableFrames else {
            return failClosed("input_too_short")
        }

        let grid = makeGrid(config)
        var summedBandPower = [Double](repeating: 0, count: grid.centers.count)
        var windowsAnalyzed = 0

        for channel in channels {
            var samples = channel
            // DC removal (pipeline): subtract per-channel mean so a DC offset cannot
            // masquerade as low-frequency energy. Removing this block lights up the lowest
            // band for the sine+DC fixture (mutation test).
            if removeDC {
                let mean = samples.reduce(0, +) / Double(samples.count)
                for i in 0..<samples.count { samples[i] -= mean }
            }

            let (psHi, framesHi) = welchPowerSpectrum(samples, windowSize: config.windowLarge, overlap: config.overlap)
            let (psLo, framesLo) = welchPowerSpectrum(samples, windowSize: config.windowSmall, overlap: config.overlap)
            windowsAnalyzed += framesHi + framesLo

            let bandsHi = aggregateToBands(power: psHi, sampleRate: sampleRate, windowSize: config.windowLarge, grid: grid)
            let bandsLo = aggregateToBands(power: psLo, sampleRate: sampleRate, windowSize: config.windowSmall, grid: grid)

            // Multi-resolution stitch: a band whose LOWER edge is below the crossover takes
            // the LF (large-window) estimate — so the band straddling F_X is LF by design.
            for i in 0..<grid.centers.count {
                let useLF = grid.edges[i] < config.crossoverHz
                summedBandPower[i] += useLF ? bandsHi[i] : bandsLo[i]
            }
        }

        // Channel energy-average, floor, resonance/centroid/classification — shared with the
        // streaming file path so both produce identical output for identical samples.
        return finishAnalysis(
            summedBandPower: summedBandPower,
            channelCount: channelCount,
            windowsAnalyzed: windowsAnalyzed,
            sampleRate: sampleRate,
            durationSeconds: duration,
            analysisRef: analysisRef,
            artifactFingerprint: artifactFingerprint,
            config: config,
            grid: grid
        )
    }

    /// Which bands this grid can actually measure at `sampleRate`.
    ///
    /// A band is measurable when its edges enclose at least one FFT bin of the window it is
    /// stitched from — LF below the crossover, HF at or above it, the same rule the splice uses. It
    /// is not a runtime count: the splice is deterministic, so the answer follows from the grid and
    /// the sample rate alone.
    ///
    /// The edge bands are no ordinary exception any more. They used to absorb everything outside the
    /// grid — band 0 the whole sub-18.9 Hz region, the top band everything above the last edge — so
    /// they always received energy and this function had to call them measurable whatever their own
    /// range contained. They no longer do, so they are subject to the same test as every other band.
    static func measurableBands(grid: BandGrid, sampleRate: Double, config: Config = .default) -> [Bool] {
        let n = grid.centers.count
        guard n > 0, sampleRate > 0 else { return [] }
        return (0..<n).map { i in
            let window = grid.edges[i] < config.crossoverHz ? config.windowLarge : config.windowSmall
            let df = sampleRate / Double(window)
            guard df > 0 else { return false }
            // The lowest bin index at or above the band's lower edge, and whether it is still below
            // the upper edge — i.e. does any k * df land inside [lo, hi).
            let firstBin = (grid.edges[i] / df).rounded(.up)
            return firstBin * df < grid.edges[i + 1] && Int(firstBin) <= window / 2
        }
    }

    /// Shared tail: energy-average per-channel band powers (NOT sum-to-mono, which cancels
    /// out-of-phase stereo), floor, then resonance/centroid/peaks/classification.
    private static func finishAnalysis(
        summedBandPower: [Double],
        channelCount: Int,
        windowsAnalyzed: Int,
        sampleRate: Double,
        durationSeconds: Double,
        analysisRef: String,
        artifactFingerprint: String,
        config: Config,
        grid: BandGrid
    ) -> SpectralAnalysisResult {
        let mode = ChannelMode(channelCount: channelCount)
        let denom = Double(max(channelCount, 1))
        var bandPower = summedBandPower.map { $0 / denom }

        // Defense-in-depth (I4b): a non-finite band power must never reach serialization.
        for i in 0..<bandPower.count where !bandPower[i].isFinite {
            return SpectralAnalysisResult(
                analysisRef: analysisRef, bands: [], resonances: [], classification: .unknown,
                confidence: 0, complete: false, partialReason: "non_finite_input",
                artifactFingerprint: artifactFingerprint, sampleRate: sampleRate,
                channelCount: channelCount, durationSeconds: durationSeconds, windowsAnalyzed: 0,
                channelMode: mode, spectralCentroidHz: nil, frequencyPeaks: []
            )
        }

        let floorLin = pow(10.0, config.floorDbfs / 10.0)
        for i in 0..<bandPower.count { bandPower[i] = max(bandPower[i], floorLin) }
        let bandsDb = bandPower.map { 10.0 * log10($0) }

        let measurable = measurableBands(grid: grid, sampleRate: sampleRate, config: config)
        let bands = zip(grid.centers, bandsDb).enumerated().map { index, pair in
            SpectralBand(centerHz: pair.0, energyDb: pair.1,
                         measured: index < measurable.count ? measurable[index] : true)
        }
        let resonances = detectResonances(
            centers: grid.centers, db: bandsDb, measurable: measurable, config: config, grid: grid)
        let (centroid, peaks) = centroidAndPeaks(centers: grid.centers, db: bandsDb, power: bandPower, config: config)
        let (classification, confidence) = classify(centers: grid.centers, power: bandPower, centroid: centroid, config: config)

        return SpectralAnalysisResult(
            analysisRef: analysisRef,
            bands: bands,
            resonances: resonances,
            classification: classification,
            confidence: confidence,
            complete: true,
            partialReason: nil,
            artifactFingerprint: artifactFingerprint,
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationSeconds: durationSeconds,
            windowsAnalyzed: windowsAnalyzed,
            channelMode: mode,
            spectralCentroidHz: centroid,
            frequencyPeaks: peaks
        )
    }

    // MARK: - Public file entry (safe path → identity-bound streaming decode)

    static func analyzeFile(
        path: String,
        analysisRef: String,
        artifactFingerprint: String,
        policy: AudioAnalyzer.AnalysisPolicy = .default,
        runtime: AudioAnalyzer.Runtime = .production,
        config: Config = .default,
        chunkFrames: Int = 64_000,
        identityProbe: IdentityProbe = .production
    ) throws -> SpectralAnalysisResult {
        // Reuse the SHIPPED path-safety model (absolute-only, traversal/iCloud rejected,
        // symlink-resolved-then-containment). Rethrows AudioAnalyzer.AnalysisError.
        let url = try AudioAnalyzer.validatedURL(path, policy: policy, runtime: runtime)
        let resolved = url.path

        // Bind file identity across the check→use gap: open once, require a regular file,
        // and hold the descriptor (O_NOFOLLOW guards a swapped final component) so the inode
        // cannot be replaced from under the decoder.
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw FeatureExtractionError.unreadable(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var fdInfo = stat()
        guard fstat(fd, &fdInfo) == 0 else {
            throw FeatureExtractionError.unreadable("fstat failed")
        }
        guard (fdInfo.st_mode & S_IFMT) == S_IFREG else {
            throw FeatureExtractionError.specialFile("non-regular file (fifo/device/socket) rejected")
        }
        // Compute cap: reject an over-cap file from the descriptor's own size (no extra
        // syscall) before opening the decoder, so an oversize input never starts work.
        if let maxBytes = policy.maximumInputFileSizeBytes, maxBytes > 0, Int64(fdInfo.st_size) > maxBytes {
            return SpectralAnalysisResult(
                analysisRef: analysisRef, bands: [], resonances: [], classification: .unknown,
                confidence: 0, complete: false, partialReason: "input_too_large",
                artifactFingerprint: artifactFingerprint, sampleRate: 0, channelCount: 0,
                durationSeconds: 0, windowsAnalyzed: 0, channelMode: .mono,
                spectralCentroidHz: nil, frequencyPeaks: []
            )
        }
        let fdIdentity = (dev: Int64(fdInfo.st_dev), ino: UInt64(fdInfo.st_ino))

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw FeatureExtractionError.decode(error.localizedDescription)
        }
        // TOCTOU: require the path still resolves to the SAME inode the held descriptor is
        // bound to — a mismatch means the path was swapped and we fail closed.
        let pathIdentity = try identityProbe.statIdentity(resolved)
        guard pathIdentity.dev == fdIdentity.dev, pathIdentity.ino == fdIdentity.ino else {
            throw FeatureExtractionError.pathIdentityChanged
        }

        // Native-format decode only — no implicit AVAudioConverter SRC/downmix.
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let declared = file.length
        guard sampleRate > 0, channelCount > 0, declared > 0 else {
            throw FeatureExtractionError.decode("empty or unreadable audio stream")
        }

        let bufferFrames = AVAudioFrameCount(max(1, chunkFrames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames) else {
            throw FeatureExtractionError.decode("could not allocate PCM buffer")
        }

        // Bounded streaming: read chunks into the reused buffer; memory stays O(window +
        // bands + chunk), independent of file length.
        let reset: () throws -> Void = { file.framePosition = 0 }
        let nextChunk: (Int) throws -> [[Double]] = { maxFrames in
            // AVAudioFile.read throws when frameCount exceeds the frames remaining, so cap
            // the request by (length − position) and stop cleanly at EOF.
            let remaining = file.length - file.framePosition
            if remaining <= 0 { return [[Double]](repeating: [], count: channelCount) }
            let cap = min(max(1, maxFrames), Int(buffer.frameCapacity))
            let want = AVAudioFrameCount(min(Int64(cap), remaining))
            try file.read(into: buffer, frameCount: want)
            let read = Int(buffer.frameLength)
            if read == 0 { return [[Double]](repeating: [], count: channelCount) }
            guard let data = buffer.floatChannelData else {
                throw FeatureExtractionError.decode("decoded audio is not float PCM")
            }
            var out = [[Double]](repeating: [], count: channelCount)
            for ch in 0..<channelCount {
                let ptr = data[ch]
                var col = [Double](repeating: 0, count: read)
                for i in 0..<read { col[i] = Double(ptr[i]) }
                out[ch] = col
            }
            return out
        }

        return analyzeStreaming(
            declaredFrameLength: declared,
            sampleRate: sampleRate,
            channelCount: channelCount,
            analysisRef: analysisRef,
            artifactFingerprint: artifactFingerprint,
            config: config,
            chunkFrames: chunkFrames,
            maxDurationSeconds: policy.maximumInputDurationSeconds,
            maxDecodedFrames: policy.maximumDecodedFrames,
            reset: reset,
            nextChunk: nextChunk
        )
    }

    // MARK: - Bounded streaming core (two-pass; O(window+bands) memory)

    /// Two-pass streaming analysis: pass 1 accumulates the per-channel mean (for DC removal),
    /// counts decoded frames (truncation), and scans for non-finite samples; pass 2 runs the
    /// mean-subtracted sliding Welch. Frames are extracted in increasing start order across
    /// chunk boundaries, so the result is identical to the whole-file path for the same
    /// samples. Content faults fail closed (never `complete:true`); a short read or a
    /// decoded-vs-declared shortfall is `decode_truncated`; an over-cap declared length or
    /// (defensively) an over-cap delivered length is `input_too_long`. `maxDurationSeconds`
    /// and `maxDecodedFrames` carry the caller's compute caps (nil = uncapped).
    static func analyzeStreaming(
        declaredFrameLength: Int64,
        sampleRate: Double,
        channelCount: Int,
        analysisRef: String,
        artifactFingerprint: String,
        config: Config = .default,
        chunkFrames: Int = 64_000,
        maxDurationSeconds: Double? = nil,
        maxDecodedFrames: Int64? = nil,
        reset: () throws -> Void,
        nextChunk: (Int) throws -> [[Double]]
    ) -> SpectralAnalysisResult {
        let mode = ChannelMode(channelCount: channelCount)
        let chunk = max(1, chunkFrames)

        func failClosed(_ reason: String, frames: Int64) -> SpectralAnalysisResult {
            let dur = sampleRate > 0 ? Double(max(frames, 0)) / sampleRate : 0
            return SpectralAnalysisResult(
                analysisRef: analysisRef, bands: [], resonances: [], classification: .unknown,
                confidence: 0, complete: false, partialReason: reason,
                artifactFingerprint: artifactFingerprint, sampleRate: sampleRate,
                channelCount: channelCount, durationSeconds: dur, windowsAnalyzed: 0,
                channelMode: mode, spectralCentroidHz: nil, frequencyPeaks: []
            )
        }

        guard channelCount > 0, sampleRate > 0, declaredFrameLength >= Int64(minAnalyzableFrames) else {
            return failClosed("input_too_short", frames: max(declaredFrameLength, 0))
        }

        // Compute caps (AnalysisPolicy limits): reject an over-cap declared length BEFORE
        // streaming any samples, so a multi-hour file never starts analysis.
        if let maxFrames = maxDecodedFrames, maxFrames > 0, declaredFrameLength > maxFrames {
            return failClosed("input_too_long", frames: declaredFrameLength)
        }
        if let maxDuration = maxDurationSeconds, maxDuration > 0,
           Double(declaredFrameLength) / sampleRate > maxDuration {
            return failClosed("input_too_long", frames: declaredFrameLength)
        }

        // Pass 1: mean + truncation + non-finite.
        var sums = [Double](repeating: 0, count: channelCount)
        var decoded: Int64 = 0
        var nonFinite = false
        do {
            try reset()
            while true {
                let block = try nextChunk(chunk)
                let frames = block.first?.count ?? 0
                if frames == 0 { break }
                guard block.count == channelCount else { return failClosed("decode_truncated", frames: decoded) }
                // Compute caps checked BEFORE accumulating this chunk: a chunk that would push
                // the total past the cap (frames, or duration — which binds first at low sample
                // rates) is rejected without feeding ANY of its frames into the mean. A chunk
                // landing exactly at the cap is still processed.
                let projected = decoded + Int64(frames)
                if let maxFrames = maxDecodedFrames, maxFrames > 0, projected > maxFrames {
                    return failClosed("input_too_long", frames: decoded)
                }
                if let maxDuration = maxDurationSeconds, maxDuration > 0,
                   Double(projected) / sampleRate > maxDuration {
                    return failClosed("input_too_long", frames: decoded)
                }
                for ch in 0..<channelCount {
                    let col = block[ch]
                    guard col.count == frames else { return failClosed("decode_truncated", frames: decoded) }
                    var s = 0.0
                    for v in col {
                        if !v.isFinite { nonFinite = true }
                        s += v
                    }
                    sums[ch] += s
                }
                decoded += Int64(frames)
            }
        } catch {
            return failClosed("decode_truncated", frames: decoded)
        }
        if nonFinite { return failClosed("non_finite_input", frames: decoded) }
        if decoded < declaredFrameLength { return failClosed("decode_truncated", frames: decoded) }
        guard decoded >= Int64(minAnalyzableFrames) else { return failClosed("input_too_short", frames: decoded) }

        let means = sums.map { $0 / Double(decoded) }
        let grid = makeGrid(config)

        // Pass 2: mean-subtracted sliding Welch at both window sizes, per channel.
        var welchHi = [SlidingWelch]()
        var welchLo = [SlidingWelch]()
        for _ in 0..<channelCount {
            guard let hi = SlidingWelch(windowSize: config.windowLarge, overlap: config.overlap),
                  let lo = SlidingWelch(windowSize: config.windowSmall, overlap: config.overlap) else {
                return failClosed("input_too_short", frames: decoded)
            }
            welchHi.append(hi)
            welchLo.append(lo)
        }

        var decoded2: Int64 = 0
        do {
            try reset()
            while true {
                let block = try nextChunk(chunk)
                let frames = block.first?.count ?? 0
                if frames == 0 { break }
                guard block.count == channelCount else { return failClosed("decode_truncated", frames: decoded2) }
                // Bound BEFORE ingest: a chunk that would push pass 2 past pass 1's
                // authoritative count is rejected without feeding ANY of its frames into the
                // DSP accumulators, so a source that lies differently on the second read
                // cannot corrupt the statistics or stream unbounded.
                if decoded2 + Int64(frames) > decoded { return failClosed("decode_truncated", frames: decoded2) }
                for ch in 0..<channelCount {
                    var col = block[ch]
                    guard col.count == frames else { return failClosed("decode_truncated", frames: decoded2) }
                    let m = means[ch]
                    for i in 0..<col.count { col[i] -= m }
                    welchHi[ch].ingest(col[...])
                    welchLo[ch].ingest(col[...])
                }
                decoded2 += Int64(frames)
            }
        } catch {
            return failClosed("decode_truncated", frames: decoded2)
        }
        if decoded2 != decoded { return failClosed("decode_truncated", frames: decoded2) }

        var summedBandPower = [Double](repeating: 0, count: grid.centers.count)
        var windowsAnalyzed = 0
        for ch in 0..<channelCount {
            let (psHi, framesHi) = welchHi[ch].finalize()
            let (psLo, framesLo) = welchLo[ch].finalize()
            windowsAnalyzed += framesHi + framesLo
            let bandsHi = aggregateToBands(power: psHi, sampleRate: sampleRate, windowSize: config.windowLarge, grid: grid)
            let bandsLo = aggregateToBands(power: psLo, sampleRate: sampleRate, windowSize: config.windowSmall, grid: grid)
            for i in 0..<grid.centers.count {
                summedBandPower[i] += (grid.edges[i] < config.crossoverHz) ? bandsHi[i] : bandsLo[i]
            }
        }

        return finishAnalysis(
            summedBandPower: summedBandPower,
            channelCount: channelCount,
            windowsAnalyzed: windowsAnalyzed,
            sampleRate: sampleRate,
            durationSeconds: Double(decoded) / sampleRate,
            analysisRef: analysisRef,
            artifactFingerprint: artifactFingerprint,
            config: config,
            grid: grid
        )
    }

    // MARK: - vDSP Welch power spectrum

    /// One-sided, dimensionless, ENBW-normalized (N·Σw²) average power spectrum over Hann
    /// frames at the given overlap. Bin-sum over a band recovers true signal power; a
    /// full-scale bin-center sine's band sum is exactly A²/2. Returns bins 0…N/2 (DC…Nyquist).
    static func welchPowerSpectrum(
        _ samples: [Double],
        windowSize n: Int,
        overlap: Double
    ) -> (power: [Double], frames: Int) {
        guard n >= 2, n & (n - 1) == 0 else { return ([], 0) }   // power-of-two only
        let half = n / 2
        guard samples.count >= n else { return ([], 0) }
        let hop = max(1, Int((Double(n) * (1.0 - overlap)).rounded()))
        let (window, _, s2) = hannWindow(n)
        let norm = Double(n) * s2                                 // ENBW normalization
        let log2n = vDSP_Length((log2(Double(n))).rounded())

        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetupD(setup) }

        var acc = [Double](repeating: 0, count: half + 1)
        var realp = [Double](repeating: 0, count: half)
        var imagp = [Double](repeating: 0, count: half)
        var windowed = [Double](repeating: 0, count: n)
        var frames = 0
        var start = 0

        while start + n <= samples.count {
            accumulateFrame(
                source: samples, start: start, window: window, n: n, half: half, norm: norm,
                setup: setup, log2n: log2n, windowed: &windowed, realp: &realp, imagp: &imagp, acc: &acc
            )
            frames += 1
            start += hop
        }

        guard frames > 0 else { return ([], 0) }
        let inv = 1.0 / Double(frames)
        for i in 0..<acc.count { acc[i] *= inv }
        return (acc, frames)
    }

    /// Accumulate one Hann-windowed frame's one-sided, ENBW-normalized power into `acc`
    /// (bins 0…N/2). Shared by the whole-array and streaming paths so both perform identical
    /// per-frame arithmetic in identical order.
    static func accumulateFrame(
        source: [Double], start: Int,
        window: [Double], n: Int, half: Int, norm: Double,
        setup: FFTSetupD, log2n: vDSP_Length,
        windowed: inout [Double], realp: inout [Double], imagp: inout [Double],
        acc: inout [Double]
    ) {
        for i in 0..<n { windowed[i] = source[start + i] * window[i] }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { cp in
                        vDSP_ctozD(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // vDSP packed real FFT: rp[0]=2·DC, ip[0]=2·Nyquist, rp[k]/ip[k]=2·Re/Im.
                // Undo the ×2 (·0.5) to match the standard DFT, then |X|² = re²+im².
                let dc = rp[0] * 0.5
                let nyq = ip[0] * 0.5
                acc[0] += (dc * dc) / norm                    // DC: no one-sided doubling
                acc[half] += (nyq * nyq) / norm               // Nyquist: no one-sided doubling
                for k in 1..<half {
                    let re = rp[k] * 0.5
                    let im = ip[k] * 0.5
                    acc[k] += 2.0 * (re * re + im * im) / norm // one-sided: double the mids
                }
            }
        }
    }

    // MARK: - Sliding Welch accumulator (streaming; O(window+chunk) buffer)

    /// Extracts Hann frames from an incrementally-fed sample stream, holding at most a
    /// window-plus-chunk tail so windows that span chunk boundaries are handled without
    /// buffering the whole signal. Frames are emitted in increasing start order.
    final class SlidingWelch {
        let n: Int
        let hop: Int
        private let half: Int
        private let norm: Double
        private let window: [Double]
        private let setup: FFTSetupD
        private let log2n: vDSP_Length
        private var acc: [Double]
        private var windowed: [Double]
        private var realp: [Double]
        private var imagp: [Double]
        private var buffer: [Double] = []
        private var consumed = 0        // absolute index of buffer[0]
        private var nextFrameStart = 0
        private(set) var frames = 0

        init?(windowSize n: Int, overlap: Double) {
            guard n >= 2, n & (n - 1) == 0 else { return nil }
            let (window, _, s2) = AudioFeatureExtractionEngine.hannWindow(n)
            let log2n = vDSP_Length((log2(Double(n))).rounded())
            guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return nil }
            self.n = n
            self.hop = max(1, Int((Double(n) * (1.0 - overlap)).rounded()))
            self.half = n / 2
            self.norm = Double(n) * s2
            self.window = window
            self.setup = setup
            self.log2n = log2n
            self.acc = [Double](repeating: 0, count: n / 2 + 1)
            self.windowed = [Double](repeating: 0, count: n)
            self.realp = [Double](repeating: 0, count: n / 2)
            self.imagp = [Double](repeating: 0, count: n / 2)
        }

        deinit { vDSP_destroy_fftsetupD(setup) }

        func ingest(_ samples: ArraySlice<Double>) {
            buffer.append(contentsOf: samples)
            while nextFrameStart + n <= consumed + buffer.count {
                let localStart = nextFrameStart - consumed
                AudioFeatureExtractionEngine.accumulateFrame(
                    source: buffer, start: localStart, window: window, n: n, half: half, norm: norm,
                    setup: setup, log2n: log2n, windowed: &windowed, realp: &realp, imagp: &imagp, acc: &acc
                )
                frames += 1
                nextFrameStart += hop
            }
            // Drop samples before the next frame start — keeps the tail bounded.
            let trim = min(nextFrameStart - consumed, buffer.count)
            if trim > 0 {
                buffer.removeFirst(trim)
                consumed += trim
            }
        }

        func finalize() -> (power: [Double], frames: Int) {
            guard frames > 0 else { return ([], 0) }
            let inv = 1.0 / Double(frames)
            return (acc.map { $0 * inv }, frames)
        }
    }

    private static func aggregateToBands(
        power ps: [Double],
        sampleRate fs: Double,
        windowSize n: Int,
        grid: BandGrid
    ) -> [Double] {
        var bands = [Double](repeating: 0, count: grid.centers.count)
        guard !ps.isEmpty else { return bands }
        let df = fs / Double(n)
        for k in 0..<ps.count {
            bands[grid.bandIndex(forFrequency: Double(k) * df)] += ps[k]
        }
        return bands
    }

    /// Periodic Hann w[n] = 0.5 − 0.5·cos(2πn/N) (matches the calibration prototype).
    /// Returns (window, S1=Σw, S2=Σw²).
    static func hannWindow(_ n: Int) -> (window: [Double], s1: Double, s2: Double) {
        var window = [Double](repeating: 0, count: n)
        var s1 = 0.0
        var s2 = 0.0
        let k = 2.0 * Double.pi / Double(n)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(k * Double(i))
            window[i] = w
            s1 += w
            s2 += w * w
        }
        return (window, s1, s2)
    }

    // MARK: - Resonance detection (prominence, not magnitude — the pinned configuration)

    private static func detectResonances(
        centers: [Double],
        db: [Double],
        measurable: [Bool],
        config: Config,
        grid: BandGrid
    ) -> [SpectralResonance] {
        let half = max(1, Int((Double(config.bandsPerOctave) * config.resonanceHalfWindowOctaves).rounded()))
        let floorGate = config.floorDbfs + 1.0
        var out = [SpectralResonance]()

        for i in 0..<centers.count {
            guard db[i] > floorGate else { continue }
            // An unmeasurable band is not a candidate. Band 0 is above the floor because it
            // ACCUMULATES everything below the grid, so the floor gate does not exclude it, and on
            // material with real sub-20 Hz content that sum makes it look like a resonance —
            // measured: pink noise drew a -9.4 dB cut at 20 Hz with nothing wrong at 20 Hz.
            guard measurable.isEmpty || (i < measurable.count && measurable[i]) else { continue }
            let lo = max(0, i - half)
            let hi = min(centers.count - 1, i + half)
            // Unmeasurable bands sit at the floor for every signal, so leaving them in the window
            // drags the median down and inflates the prominence of everything beside them — a
            // resonance manufactured by the grid rather than found in the audio. They are excluded
            // from the baseline, not from the spectrum.
            let window = (lo...hi).filter { measurable.isEmpty || ($0 < measurable.count && measurable[$0]) }
                .map { db[$0] }
            let baseline = median(window.isEmpty ? Array(db[lo...hi]) : window)
            let prominence = db[i] - baseline
            let leftOk = i == 0 || db[i] >= db[i - 1]
            let rightOk = i == centers.count - 1 || db[i] >= db[i + 1]

            // Prominence guard: a broad hump has neighbours as high as its peak, so its
            // prominence is ~0 and it is rejected; only a locally-prominent narrow peak
            // survives. Removing `prominence >= P_min` lets the broad-hump companion be
            // reported (mutation test).
            guard prominence >= config.prominenceMinDb, leftOk, rightOk else { continue }

            let (widthOctaves, bandwidthHz, resolutionLimited) = threeDbWidth(peak: i, db: db, centers: centers, grid: grid)
            // Bandwidth guard: reject a peak broader than the resonance ceiling (a hump).
            guard widthOctaves <= config.maxResonanceWidthOctaves else { continue }

            let q = bandwidthHz > 0 ? centers[i] / bandwidthHz : 0
            out.append(SpectralResonance(hz: centers[i], gainDb: prominence, q: q, resolutionLimited: resolutionLimited))
        }
        return out
    }

    /// −3 dB width around a peak, approximated on the log-band grid. When both −3 dB points
    /// fall inside the peak band itself the width is unresolved: it is clamped to the band
    /// spacing (resolution ceiling) and flagged so Q is reported as ">= ceiling", never
    /// unbounded (pinned rule).
    private static func threeDbWidth(
        peak: Int,
        db: [Double],
        centers: [Double],
        grid: BandGrid
    ) -> (octaves: Double, hz: Double, resolutionLimited: Bool) {
        let target = db[peak] - 3.0
        var l = peak
        while l > 0 && db[l - 1] > target { l -= 1 }
        var r = peak
        while r < db.count - 1 && db[r + 1] > target { r += 1 }

        let bandSpacingHz = grid.edges[peak + 1] - grid.edges[peak]
        if l == peak && r == peak {
            let octaves = log2(grid.edges[peak + 1] / grid.edges[peak])
            return (octaves, bandSpacingHz, true)
        }
        let hz = max(centers[r] - centers[l], bandSpacingHz)
        let octaves = log2(centers[r] / centers[l])
        return (octaves, hz, false)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : 0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
    }

    // MARK: - Centroid, peaks, classification (advisory, computed — rollout-1 schema)

    private static func centroidAndPeaks(
        centers: [Double],
        db: [Double],
        power: [Double],
        config: Config
    ) -> (centroid: Double?, peaks: [AudioAnalyzer.FrequencyPeak]) {
        let gate = config.floorDbfs + 3.0
        var num = 0.0
        var den = 0.0
        for i in 0..<centers.count where db[i] > gate {
            num += centers[i] * power[i]
            den += power[i]
        }
        let centroid: Double? = den > 0 ? num / den : nil

        // Frequency peaks = local maxima above the floor, strongest first, top 5. magnitude
        // is the linear band power (computed, never a placeholder).
        var maxima = [(hz: Double, magnitude: Double)]()
        for i in 0..<centers.count where db[i] > gate {
            let leftOk = i == 0 || db[i] >= db[i - 1]
            let rightOk = i == centers.count - 1 || db[i] >= db[i + 1]
            if leftOk && rightOk { maxima.append((centers[i], power[i])) }
        }
        maxima.sort { $0.magnitude > $1.magnitude }
        let peaks = maxima.prefix(5).map { AudioAnalyzer.FrequencyPeak(frequencyHz: $0.hz, magnitude: $0.magnitude) }
        return (centroid, Array(peaks))
    }

    private static func regionEnergy(_ centers: [Double], _ power: [Double], _ lo: Double, _ hi: Double) -> Double {
        var sum = 0.0
        for i in 0..<centers.count where centers[i] >= lo && centers[i] < hi { sum += power[i] }
        return sum
    }

    /// Coarse, advisory classification + confidence (out-of-scope for this rollout beyond coarse). A
    /// near-silent signal is `unknown` with ~0 confidence, which the recommendation layer
    /// fails closed on. Confidence is capped below 1 — the classifier is coarse and must
    /// not over-claim certainty.
    private static func classify(
        centers: [Double],
        power: [Double],
        centroid: Double?,
        config: Config
    ) -> (SourceClassification, Double) {
        let total = power.reduce(0, +)
        guard total > 0, let centroid else { return (.unknown, 0) }
        let overallDb = 10.0 * log10(total)
        // Level gate: below ~-60 dBFS overall → 0 confidence (silence); ~-20 dBFS → 1.
        let level = min(max((overallDb + 60.0) / 40.0, 0.0), 1.0)
        guard level > 0 else { return (.unknown, 0) }

        let low = regionEnergy(centers, power, 0, 250) / total
        let high = regionEnergy(centers, power, 4_000, .infinity) / total
        let mid = regionEnergy(centers, power, 250, 4_000) / total

        let classification: SourceClassification
        if low > 0.6 && centroid < 250 {
            classification = .bass
        } else if high > 0.5 {
            classification = .drums
        } else if mid > 0.5 && centroid >= 250 && centroid < 4_000 {
            classification = .vocal
        } else {
            classification = .fullMix
        }
        // Cap confidence: coarse heuristic, never claim full certainty.
        let confidence = min(0.9, level)
        return (classification, confidence)
    }

}
