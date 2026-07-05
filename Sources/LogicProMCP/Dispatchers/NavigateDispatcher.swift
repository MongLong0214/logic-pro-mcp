import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: "Navigation and markers in Logic Pro. Commands: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view. UNSUPPORTED: rename_marker is NOT implemented — there is no verified AX write path on Logic 12.x, so it always fails closed with State C error=not_implemented; to rename, delete_marker the target then create_marker with the new name. BREAKING since v3.3.0: delete_marker / rename_marker require explicit `index` (Int ≥ 0) — pre-v3.3.0 missing `index` defaulted to 0 and silently mutated marker 0; rename_marker now also rejects empty `name`. Params: goto_bar -> { bar: Int }; goto_marker -> { index: Int } or { name: String }; create_marker -> { name: String }; rename_marker -> { index: Int (required, ≥ 0), name: String (required, non-empty) } (not implemented: returns not_implemented); delete_marker -> { index: Int (required, ≥ 0) }; set_zoom -> { level: String } (in|out|fit); toggle_view -> { view: String } (mixer|piano_roll|score|step_editor|library|inspector|automation).",
        inputSchema: commandParamsToolSchema(commandDescription: "Navigation command to execute")
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "goto_bar":
            guard params["bar"] != nil else {
                return toolInvalidParamsResult(
                    "goto_bar requires explicit 'bar'"
                )
            }
            guard let bar = intParamOrNil(params, "bar") else {
                return toolInvalidParamsResult(
                    "goto_bar 'bar' must be an integer in 1..9999"
                )
            }
            guard (1...9999).contains(bar) else {
                return toolInvalidParamsResult(
                    "goto_bar 'bar' must be in 1..9999 (got \(bar))"
                )
            }
            let result = await router.route(
                operation: "transport.goto_position",
                params: ["position": "\(bar).1.1.1"]
            )
            return await TransportDispatcher.finalizeGotoPositionResult(
                result,
                requestedPosition: "\(bar).1.1.1",
                router: router,
                cache: cache
            )

        case "goto_marker":
            // v3.1.10 (boomer P1-1) — resolve the target marker from cache and
            // navigate via `transport.goto_position` using its `position`
            // string. Pre-v3.1.10 this routed to `nav.goto_marker` →
            // `MIDIKeyCommandsChannel` CC 38 (Logic's "go to next marker"
            // hotkey), which ignores params entirely and just advances the
            // marker pointer by one — making both index- and name-based
            // goto silent no-ops relative to their parameter.
            //
            let markers = await cache.getMarkers()
            func routeMarkerTarget(_ target: MarkerState) async -> CallTool.Result {
                var result = await router.route(
                    operation: "transport.goto_position",
                    params: ["position": target.position]
                )
                // canonical 마커는 응답 그대로. fallback/unknown 만 uncertainty
                // 머신 가독으로 surface (HC State A/B 한정; State C 보존).
                if !target.positionSource.isCanonical {
                    let merged = mergeMarkerUncertainty(
                        into: result.message, source: target.positionSource
                    )
                    result = result.isSuccess ? .success(merged) : .error(merged)
                }
                return await TransportDispatcher.finalizeGotoPositionResult(
                    result,
                    requestedPosition: target.position,
                    router: router,
                    cache: cache
                )
            }
            // H-2 (2026-05-08 enterprise review): pre-fix the cache-cold
            // index-based path fell back to `nav.goto_marker` (CC 38), which
            // is Logic's "go to next marker" hotkey — it advances the marker
            // pointer by one regardless of the requested index. A caller
            // saying "goto_marker { index: 5 }" with a cold cache silently
            // got "go to whatever marker comes next." That violates the
            // target-faithful contract every other dispatcher honors.
            //
            // Fix: when the target can't be resolved against the cache,
            // return State C (`element_not_found`) with a hint pointing the
            // caller at the cache freshness state. The caller can then
            // decide whether to refresh the cache and retry, or accept the
            // failure. No silent wrong-target navigation.
            if params["index"] != nil {
                guard let index = intParamOrNil(params, "index"), index >= 0 else {
                    return toolInvalidParamsResult(
                        "goto_marker 'index' must be an integer >= 0"
                    )
                }
                if let target = markers.first(where: { $0.id == index }) {
                    return await routeMarkerTarget(target)
                }
                let indexStr = String(index)
                return toolTextResult(
                    HonestContract.encodeStateC(
                        error: .elementNotFound,
                        hint: "goto_marker: marker index \(indexStr) not found in cached marker list (count=\(markers.count)). The marker list cache may be cold (poller hasn't refreshed, or the marker list window is closed on Logic 12.2). Try `system.refresh_cache` and retry, or supply `name` instead. Pre-v3.4.0 this fell back to the legacy CC 38 keycmd which silently advanced to the next marker — this fallback is removed because it ignored the requested index.",
                        extras: [
                            "requested_index": indexStr,
                            "cached_marker_count": markers.count,
                        ]
                    ),
                    isError: true
                )
            }
            let name = stringParam(params, "name")
            if name.isEmpty {
                return toolInvalidParamsResult(
                    "goto_marker requires 'index' or 'name' param",
                    extras: ["operation": "nav.goto_marker"]
                )
            }
            if let target = markers.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return await routeMarkerTarget(target)
            }
            return toolTextResult(
                HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "goto_marker: no marker matching name '\(name)' in cached list (count=\(markers.count)). Try `system.refresh_cache` and retry.",
                    extras: [
                        "requested_name": name,
                        "cached_marker_count": markers.count,
                    ]
                ),
                isError: true
            )

        case "create_marker":
            let providedName = stringParam(params, "name")
            return await finalizeCreateMarkerResult(
                requestedName: providedName.isEmpty ? nil : providedName,
                router: router,
                cache: cache
            )

        case "delete_marker":
            // RB-1.b (2026-05-08 enterprise review): pre-fix `intParam(default: 0)`
            // silently deleted marker 0 when `index` was missing/malformed.
            // Marker mutations are not undoable in the same project session,
            // so missing/negative target now fails closed.
            guard let index = intParamOrNil(params, "index"), index >= 0 else {
                return toolInvalidParamsResult(
                    "delete_marker requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "nav.delete_marker"]
                )
            }
            let result = await router.route(
                operation: "nav.delete_marker",
                params: ["index": String(index)]
            )
            return toolTextResult(result)

        case "rename_marker":
            // RB-1.b — same fail-closed treatment for index, plus reject empty
            // `name` (a blank rename overwrote the marker label silently).
            guard let index = intParamOrNil(params, "index"), index >= 0 else {
                return toolInvalidParamsResult(
                    "rename_marker requires explicit 'index' (Int ≥ 0)",
                    extras: ["operation": "nav.rename_marker"]
                )
            }
            let name = stringParam(params, "name")
            guard !name.isEmpty else {
                return toolInvalidParamsResult(
                    "rename_marker requires non-empty 'name'",
                    extras: ["operation": "nav.rename_marker"]
                )
            }
            let result = await router.route(
                operation: "nav.rename_marker",
                params: ["index": String(index), "name": name]
            )
            return toolTextResult(result)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return toolTextResultTreatingUnverifiedAsError(result)

        case "set_zoom":
            // Accept both `level` (docs) and `direction` (common caller term) —
            // matrix tests and real callers drift across both. Silently ignoring
            // a misnamed param was the class of bug that hid 100% false-positive
            // test coverage earlier in the hardening loop.
            guard params["level"] != nil || params["direction"] != nil else {
                return toolInvalidParamsResult(
                    "set_zoom requires explicit 'level' or 'direction'"
                )
            }
            let level = stringParam(params, "level", "direction", default: "fit")
            switch level {
            case "in":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "8"]
                )
                return toolTextResultTreatingUnverifiedAsError(result)
            case "out":
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": "2"]
                )
                return toolTextResultTreatingUnverifiedAsError(result)
            case "fit":
                let result = await router.route(operation: "nav.zoom_to_fit")
                return toolTextResultTreatingUnverifiedAsError(result)
            default:
                guard let numericLevel = Int(level),
                      (1...10).contains(numericLevel) else {
                    return toolInvalidParamsResult(
                        "set_zoom 'level' must be one of: in, out, fit, or integer 1..10"
                    )
                }
                let result = await router.route(
                    operation: "nav.set_zoom_level",
                    params: ["level": String(numericLevel)]
                )
                return toolTextResultTreatingUnverifiedAsError(result)
            }

        case "toggle_view":
            guard params["view"] != nil else {
                return toolInvalidParamsResult(
                    "toggle_view requires explicit 'view'"
                )
            }
            let view = stringParam(params, "view", default: "mixer")
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return toolInvalidParamsResult(
                    "Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, library, inspector, automation",
                    extras: ["operation": "nav.toggle_view"]
                )
            }
            let result = await router.route(operation: operation)
            return toolTextResult(result)

        default:
            return toolInvalidParamsResult(
                "Unknown navigate command: \(command). Available: goto_bar, goto_marker, create_marker, delete_marker, rename_marker, zoom_to_fit, set_zoom, toggle_view",
                extras: ["operation": "nav.\(command)"]
            )
        }
    }

    private static func finalizeCreateMarkerResult(
        requestedName: String?,
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let routedName = requestedName ?? "Marker"
        // audit P1 #8: snapshot the marker list BEFORE the mutating route so the
        // count-delta verify reflects the +1 this create adds. Pre-fix both the
        // "before" and "after" reads ran AFTER nav.create_marker, so their
        // counts were equal on success → every verified-by-readback create fell
        // to the State-B readback-mismatch path. Still fail-closed: a nil/short
        // readback below returns State B.
        let beforeMarkers = await liveMarkers(router: router, cache: cache)
        let routeResult = await router.route(
            operation: "nav.create_marker",
            params: ["name": routedName]
        )
        guard routeResult.isSuccess else {
            return toolTextResult(routeResult)
        }
        guard channelResultIsUnverified(routeResult) else {
            return toolTextResult(routeResult)
        }
        guard let beforeMarkers else {
            return toolTextResult(
                HonestContract.addExtras(
                    ["verification_source": "logic://markers"],
                    into: routeResult.message
                ),
                isError: true
            )
        }
        guard let afterMarkers = await liveMarkers(router: router, cache: cache) else {
            return toolTextResult(
                HonestContract.addExtras(
                    ["verification_source": "logic://markers"],
                    into: routeResult.message
                ),
                isError: true
            )
        }

        var extras = honestContractExtras(from: routeResult.message)
        extras["verification_source"] = "logic://markers"
        extras["marker_count_before"] = beforeMarkers.count
        extras["marker_count_after"] = afterMarkers.count
        if let requestedName {
            extras["requested_name"] = requestedName
        }

        let createdMarker = createdMarker(after: afterMarkers, before: beforeMarkers)
        if let createdMarker {
            extras["observed_marker_id"] = createdMarker.id
            extras["observed_marker_name"] = createdMarker.name
            extras["observed_marker_position"] = createdMarker.position
            extras["observed_marker_position_source"] = createdMarker.positionSource.rawValue
        }

        guard afterMarkers.count > beforeMarkers.count, let createdMarker else {
            return toolTextResult(
                HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras),
                isError: true
            )
        }

        if let requestedName, createdMarker.name != requestedName {
            return toolTextResult(
                HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras),
                isError: true
            )
        }

        return toolTextResult(HonestContract.encodeStateA(extras: extras))
    }

    private static func liveMarkers(
        router: ChannelRouter,
        cache: StateCache
    ) async -> [MarkerState]? {
        let readback = await router.route(operation: "nav.get_markers")
        guard readback.isSuccess,
              let markers = decodeJSONValue([MarkerState].self, from: readback.message) else {
            return nil
        }
        await cache.updateMarkers(markers)
        return markers
    }

    private static func createdMarker(
        after afterMarkers: [MarkerState],
        before beforeMarkers: [MarkerState]
    ) -> MarkerState? {
        return afterMarkers.last(where: { candidate in
            !beforeMarkers.contains(candidate)
        })
    }

    /// goto_marker 응답에 marker provenance uncertainty 를 surface — State A/B
    /// envelope 의 top-level 에 `marker_position_uncertain`/`marker_position_source`
    /// 를 merge 한다. State C (success:false) 는 보존 — `HonestContract.addExtras`
    /// 가 정책 책임.
    static func mergeMarkerUncertainty(into rawJSON: String, source: PositionSource) -> String {
        HonestContract.addExtras([
            "marker_position_uncertain": true,
            "marker_position_source": source.rawValue,
        ], into: rawJSON)
    }
}
