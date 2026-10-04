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
        track: Int, mixer: AXUIElement, runtime: AXLogicProElements.Runtime
    ) -> Binding? {
        guard track >= 0,
              case .found(let window) = AXLogicProElements.arrangeWindowVerifiedRead(runtime: runtime),
              case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: window, runtime: runtime),
              track < headers.count else { return nil }

        var headerNames: [String] = []
        for header in headers {
            guard case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                from: header, runtime: runtime.ax
            ) else { return nil }
            headerNames.append(name)
        }
        let name = headerNames[track]
        guard headerNames.filter({ $0 == name }).count == 1 else { return nil }

        // Reuse the existing noting seam so legacy role reads in stripEnumeration cannot turn
        // an AX failure into an absent sibling and thereby hide a duplicate target name.
        let failures = AXPluginInstanceIdentity.FailedReads()
        let ax = AXPluginInstanceIdentity.noting(failures, over: runtime.ax)
        guard let enumeration = AXLogicProElements.stripEnumeration(in: mixer, runtime: ax),
              enumeration.unreadableChildren == 0, !failures.any else { return nil }
        var matching: [(Int, AXUIElement)] = []
        for (index, strip) in enumeration.strips.enumerated() {
            guard case .success(.some(let stripName)) = AXPluginInstanceIdentity.stripNameResult(
                strip, runtime: runtime.ax
            ) else { return nil }
            if stripName == name { matching.append((index, strip)) }
        }
        guard matching.count == 1 else { return nil }
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
