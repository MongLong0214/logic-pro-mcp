import ApplicationServices
import Foundation

/// Plugin operations address Arrange tracks; Mixer ordinals are observations, never identity.
enum AXPluginTrackBinding {
    struct Binding: @unchecked Sendable {
        let trackIndex: Int
        let trackName: String
        let mixerStripIndex: Int
        let header: AXUIElement
        /// The acquired Mixer surface. A floating and embedded Mixer can expose different AX
        /// elements for the same track; global rediscovery must not switch between them mid-write.
        let mixer: AXUIElement
        let strip: AXUIElement
    }

    static func resolve(
        track: Int, mixer: AXUIElement, runtime: AXLogicProElements.Runtime,
        onRefusal: ((String) -> Void)? = nil
    ) -> Binding? {
        guard track >= 0 else { onRefusal?("invalid_track_index"); return nil }
        let windowRead = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime)
        guard case .found(let window) = windowRead else {
            if case .unreadable(let stage, let status) = windowRead {
                onRefusal?("arrange_window_unavailable/\(stage)/\(status)")
            } else { onRefusal?("arrange_window_unavailable") }
            return nil
        }
        let headerRead = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime)
        guard case .read(let headers) = headerRead else {
            if case .unreadable(let stage, let status) = headerRead {
                onRefusal?("arrange_headers_unavailable/\(stage)/\(status)")
            } else { onRefusal?("arrange_headers_unavailable") }
            return nil
        }
        guard track < headers.count else { onRefusal?("track_index_absent"); return nil }

        var headerNames: [String] = []
        for header in headers {
            let nameRead = AXValueExtractors.extractTrackNameResult(
                from: header, runtime: runtime.ax
            )
            guard case .success(.some(let name)) = nameRead else {
                if case .failure(let error) = nameRead {
                    onRefusal?("arrange_name_unavailable/\(error.diagnosticLabel)")
                } else { onRefusal?("arrange_name_unavailable") }
                return nil
            }
            headerNames.append(name)
        }
        let name = headerNames[track]
        // Preserve the conservative legacy join at this consumer, not in observations returned
        // to inventory/reference issuance. Normalized-equal siblings remain ambiguous.
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headerNames.filter({ $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName }).count == 1 else {
            onRefusal?("arrange_name_ambiguous"); return nil
        }

        // Reuse the existing noting seam so legacy role reads in stripEnumeration cannot turn
        // an AX failure into an absent sibling and thereby hide a duplicate target name.
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = AXPluginInstanceIdentity.noting(failures, over: runtime.ax)
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: ax),
              enumeration.unreadableChildren == 0, !failures.any else {
            onRefusal?("mixer_strips_unavailable"); return nil
        }
        var matching: [(Int, AXUIElement)] = []
        for (index, strip) in enumeration.strips.enumerated() {
            let nameRead = AXPluginInstanceIdentity.stripNameResult(
                strip, runtime: runtime.ax
            )
            guard case .success(.some(let stripName)) = nameRead else {
                if case .failure(let error) = nameRead {
                    onRefusal?("strip_name_unavailable/\(error.diagnosticLabel)")
                } else { onRefusal?("strip_name_unavailable") }
                return nil
            }
            if stripName.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName {
                matching.append((index, strip))
            }
        }
        guard matching.count == 1 else { onRefusal?("strip_name_not_unique"); return nil }
        return Binding(trackIndex: track, trackName: name, mixerStripIndex: matching[0].0,
                       header: headers[track], mixer: mixer, strip: matching[0].1)
    }

    /// The acquired Mixer's owning window, not whichever Mixer a global search currently finds.
    /// Only structural AXWindow absence permits the bounded parent fallback; unread ownership
    /// never becomes permission to raise a different window. The owner must still be in AXWindows.
    static func owningWindow(_ binding: Binding, runtime: AXLogicProElements.Runtime) -> AXUIElement? {
        func liveWindow(_ candidate: AXUIElement) -> AXUIElement? {
            guard case .success(.some(let role)) = AXHelpers.getAttributeResult(
                candidate, kAXRoleAttribute as String, runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError>, role == kAXWindowRole as String,
                  let app = AXLogicProElements.appRoot(runtime: runtime),
                  case .success(.elements(let windows)) = AXHelpers.getAXUIElementArrayRead(
                    app, kAXWindowsAttribute as String, runtime: runtime.ax
                  ),
                  windows.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }),
                  windows.contains(where: { CFEqual($0, candidate) }) else { return nil }
            return candidate
        }

        switch AXHelpers.getAttributeResult(binding.mixer, kAXWindowAttribute as String, runtime: runtime.ax)
            as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .success(.some(let value)):
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return liveWindow(unsafeBitCast(value, to: AXUIElement.self))
        case .success(.none): break
        case .failure(let error) where error.isDefinitiveAbsence: break
        case .failure: return nil
        }

        var child = binding.mixer
        var visited = [child]
        for _ in 0..<16 {
            guard case .success(.some(let parent)) = AXHelpers.getAttributeResult(
                child, kAXParentAttribute as String, runtime: runtime.ax
            ) as Result<AXUIElement?, AXHelpers.AXStatusError>,
                  !visited.contains(where: { CFEqual($0, parent) }),
                  case .success(.some(let role)) = AXHelpers.getAttributeResult(
                    parent, kAXRoleAttribute as String, runtime: runtime.ax
                  ) as Result<String?, AXHelpers.AXStatusError>, !role.isEmpty else { return nil }
            if role == kAXWindowRole as String { return liveWindow(parent) }
            visited.append(parent)
            child = parent
        }
        return nil
    }

    /// Re-resolve uniquely at use time. The same strip may move, but a replacement at the old
    /// ordinal (even with the same name) is not the acquired target.
    static func isStable(_ original: Binding, runtime: AXLogicProElements.Runtime) -> Bool {
        guard let fresh = resolve(track: original.trackIndex, mixer: original.mixer, runtime: runtime),
              fresh.trackName == original.trackName,
              CFEqual(fresh.header, original.header), CFEqual(fresh.strip, original.strip) else { return false }
        return true
    }

    /// Allow transient AX observations after selection to settle, never reacquiring a different
    /// target or Mixer. Every successful poll must still match the original name and CF identities.
    static func waitUntilStable(
        _ original: Binding, runtime: AXLogicProElements.Runtime,
        timeoutMs: Int = 1_200, intervalMs: Int = 100
    ) async -> Bool {
        guard timeoutMs > 0, intervalMs > 0 else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
        while !Task.isCancelled, clock.now < deadline {
            if isStable(original, runtime: runtime) { return !Task.isCancelled }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(intervalMs)))
            } catch {
                return false
            }
        }
        return false
    }
}
