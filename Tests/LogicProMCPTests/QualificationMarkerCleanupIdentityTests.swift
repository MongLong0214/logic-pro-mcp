import Foundation
import Testing
@testable import LogicProMCP

/// Qualification marker cleanup must never delete by a row it did not read fresh.
///
/// The marker operations close the Marker List they open, and with the list closed the product's
/// marker cache keeps its last rows and only marks them unreadable. A recipe that took its delete
/// index from those rows deleted index 0 again after its probe was already gone, and index 0 was
/// then somebody else's marker. These tests drive the real recipes against a server double whose
/// marker cache behaves that way, and require every original marker to survive.
@Suite(.serialized) struct QualificationMarkerCleanupIdentityTests {
    static let markerOperations: [OperationID] = [
        .navigateCreateMarker, .navigateRenameMarker, .navigateDeleteMarker, .navigateGotoMarker,
    ]
    static let originals = ["Verse|5.1.1.1", "Chorus|9.1.1.1"]

    struct Fixture {
        let directory: URL
        let executableURL: URL

        init(
            listOpenInitially: Bool,
            closeAfterCreate: Bool = false,
            refreshPolls: String = "when_open",
            ghostPolls: Int = 0,
            barWriteOvershoot: Bool = false,
            startBeat: Int = 1,
            refuseGotoPosition: Bool = false,
            defaultPosition: Bool = false,
            transportShape: String = "live_full",
            gotoReply: String = "ok",
            displayMode: String? = nil
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qualification-marker-cleanup-\(UUID().uuidString)", isDirectory: true)
            executableURL = directory.appendingPathComponent("server.sh")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var script = Self.script
            if listOpenInitially {
                script = script.replacingOccurrences(of: "list_open_initially=false", with: "list_open_initially=true")
            }
            if closeAfterCreate {
                script = script.replacingOccurrences(of: "close_after_create=false", with: "close_after_create=true")
            }
            script = script.replacingOccurrences(of: "refresh_polls=when_open", with: "refresh_polls=\(refreshPolls)")
            script = script.replacingOccurrences(of: "ghost_polls=0", with: "ghost_polls=\(ghostPolls)")
            if barWriteOvershoot {
                script = script.replacingOccurrences(of: "bar_overshoot=false", with: "bar_overshoot=true")
            }
            script = script.replacingOccurrences(of: "start_beat=1", with: "start_beat=\(startBeat)")
            if refuseGotoPosition {
                script = script.replacingOccurrences(of: "refuse_goto_position=false", with: "refuse_goto_position=true")
            }
            if defaultPosition {
                script = script.replacingOccurrences(of: "default_position=false", with: "default_position=true")
            }
            script = script.replacingOccurrences(of: "transport_shape=live_full", with: "transport_shape=\(transportShape)")
            script = script.replacingOccurrences(of: "goto_reply=ok", with: "goto_reply=\(gotoReply)")
            try Data(script.utf8).write(to: executableURL)
            if let displayMode {
                try Data((displayMode + "\n").utf8).write(to: directory.appendingPathComponent("display-mode"))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }

        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        /// The project's markers as the double holds them: `name|position`, in list order.
        var live: [String] { lines("live") }
        /// Every marker write the double accepted, in order.
        var writes: [String] { lines("writes") }
        /// The playhead's bar as the double holds it. Every recipe starts at bar 1.
        var bar: Int? { lines("bar").first.flatMap { Int($0) } }
        /// The playhead's beat within the bar. Every recipe starts at beat `startBeat`.
        var beat: Int? { lines("beat").first.flatMap { Int($0) } }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        static let script = #"""
        #!/bin/sh
        IFS= read -r request_line || exit 0
        sleep "$HANDSHAKE_DELAY"
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1.0"}}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"logic_pro_running\":true,\"logic_pro_version\":\"11.2\",\"logic_pro_bundle_id\":\"com.apple.logic10\",\"logic_pro_variant\":\"desktop\",\"logic_pro_ui_locale\":\"en-US\",\"logic_pro_variants\":[{\"variant\":\"desktop\",\"bundle_id\":\"com.apple.logic10\",\"installed\":true,\"running\":true},{\"variant\":\"creator_studio\",\"bundle_id\":\"com.apple.mobilelogic\",\"installed\":false,\"running\":false}],\"process_metadata_resolved\":true}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"contents":[{"uri":"logic://system/operations","text":"{\"schema_version\":1,\"generated_at\":\"1970-01-01T00:00:00Z\",\"operation_count\":0,\"operations\":[]}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"traces\":[{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000001\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"}]}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"isError":true,"content":[{"type":"text","text":"{\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"{\"traces\":[{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000002\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"},{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000001\",\"operation_id\":\"system.saga_execute\",\"phase_count\":3,\"readback_state\":\"C\"}]}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"{\"trace_id\":\"lpmcp_00000000-0000-0000-0000-000000000002\",\"operation_id\":\"system.saga_execute\",\"events\":[{\"phase\":\"request.received\"},{\"phase\":\"verification.completed\"},{\"phase\":\"result.emitted\"}]}"}]}}'
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":8,"result":{"isError":true,"content":[{"type":"text","text":"{\"state\":\"C\",\"error\":\"invalid_params\",\"write_attempted\":false}"}]}}'
        # id 9 — #373 saga seed. A REFUSED saga: the journal records the outcome and no step
        # runs. The double must simulate it, because the transport's request sequence is
        # pinned here BY ID — an unscripted step silently consumes the next response.
        /usr/bin/printf '%s\n' '{"jsonrpc":"2.0","id":9,"result":{"isError":true,"content":[{"type":"text","text":"{}"}]}}'
        cd "$(dirname "$0")" || exit 1
        list_open_initially=false
        close_after_create=false
        refresh_polls=when_open
        name_applies=true
        # `ghost_polls=N`: after a delete, the list keeps showing the deleted row for N fresh polls,
        # as Logic's AX table does while it settles (measured: still present 1.8 s after a delete).
        ghost_polls=0
        # `bar_overshoot=true`: the first bar write lands one bar past the request, so the
        # cycle's readback disagrees and it refuses with the playhead moved.
        bar_overshoot=false
        # `refuse_goto_position=true`: every goto_position is refused, so only goto_bar can move the
        # playhead, and it lands on a bar's first beat.
        refuse_goto_position=false
        default_position=false
        # `goto_reply=submitted_read_failed`: a `goto_position` moves the playhead and answers what the
        # dispatcher answers when the dialog was submitted and its own immediate read failed (State B,
        # error, `dialog_submission_attempted`). `submitted_unknown` is the same move with the
        # submission indeterminate.
        goto_reply=ok
        # What else the resource can publish for the position: `cache` (the live read failed and the
        # cache answers, StateReaders.swift:98), `unverified` (a live source flagged unverified) and
        # `prefix` (a readback that stops at bar and beat, AXValueExtractors.swift:754).
        transport_shape=live_full
        echo 0 > ghost-left
        : > ghost
        created=false
        printf 'Verse|5.1.1.1\nChorus|9.1.1.1\n' > live
        cp live originals
        : > writes
        : > cache
        echo false > cache-readable
        echo null > cache-epoch
        start_beat=1
        echo 1 > bar
        echo $start_beat > beat
        [ "$list_open_initially" = true ] && touch list-open
        now_epoch() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
        iso_of() { /usr/bin/perl -MPOSIX=strftime -e '$t = shift; printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime(int $t)), int(($t - int $t) * 1000)' "$1"; }
        age_of() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time - shift' "$1"; }
        # The product's marker cache: a successful poll copies the open list, a failed one keeps the rows
        # and only marks them unreadable (StateCache.markMarkersUnreadable).
        poll_markers() {
            if [ -f list-open ]; then
                left=$(cat ghost-left)
                if [ "$left" -gt 0 ]; then
                    cat live ghost | /usr/bin/sort -s -t'|' -k2,2n > cache; echo $((left - 1)) > ghost-left
                else cp live cache; fi
                echo true > cache-readable; now_epoch > cache-epoch; return 0
            fi
            echo false > cache-readable; return 1
        }
        rows_json() {
            i=0; out=
            while IFS='|' read -r n p; do
                [ -n "$n" ] || continue
                [ -z "$out" ] || out="$out,"
                out="$out{\\\"id\\\":$i,\\\"name\\\":\\\"$n\\\",\\\"position\\\":\\\"$p\\\",\\\"position_source\\\":\\\"parser\\\",\\\"is_canonical\\\":true}"
                i=$((i + 1))
            done < "$1"
            printf '%s' "$out"
        }
        param_string() { printf '%s' "$request" | /usr/bin/sed -n "s/.*\"params\":{[^}]*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
        param_int() { printf '%s' "$request" | /usr/bin/sed -n "s/.*\"params\":{[^}]*\"$1\":\([0-9][0-9]*\).*/\1/p"; }
        ok() { printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"state\\":\\"A\\",\\"success\\":true,\\"verified\\":true}"}]}}\n' "$id"; }
        refuse() { printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{\\"state\\":\\"C\\",\\"success\\":false,\\"error\\":\\"%s\\",\\"write_attempted\\":false}"}]}}\n' "$id" "$1"; }
        # A marker operation opens the Marker List when it is closed and closes what it opened.
        open_list() { opened=false; if [ ! -f list-open ]; then touch list-open; opened=true; fi; }
        release_list() { if [ "$opened" = true ]; then rm -f list-open; fi; }
        while IFS= read -r request; do
            id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
            [ -n "$id" ] || continue
            [ "$id" -ge 10 ] || continue
            request=$(printf '%s' "$request" | /usr/bin/sed 's#\\/#/#g')
            printf '%s\n' "$request" >> requests
            case "$request" in
              *'"uri":"logic://system/operations"'*)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://system/operations","text":"{\\"schema_version\\":1,\\"generated_at\\":\\"1970-01-01T00:00:00Z\\",\\"operation_count\\":0,\\"operations\\":[]}"}]}}\n' "$id" ;;
              *'"uri":"logic://system/health"'*)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://system/health","text":"{\\"logic_pro_running\\":true,\\"logic_pro_version\\":\\"11.2\\",\\"logic_pro_bundle_id\\":\\"com.apple.logic10\\",\\"logic_pro_variant\\":\\"desktop\\",\\"logic_pro_ui_locale\\":\\"en-US\\",\\"process_metadata_resolved\\":true}"}]}}\n' "$id" ;;
              *'"command":"health"'*)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"logic_pro_running\\":true,\\"logic_pro_version\\":\\"11.2\\",\\"logic_pro_bundle_id\\":\\"com.apple.logic10\\",\\"logic_pro_variant\\":\\"desktop\\",\\"logic_pro_ui_locale\\":\\"en-US\\",\\"process_metadata_resolved\\":true,\\"logic_pro_variants\\":[{\\"variant\\":\\"desktop\\",\\"bundle_id\\":\\"com.apple.logic10\\",\\"installed\\":true,\\"running\\":true},{\\"variant\\":\\"creator_studio\\",\\"bundle_id\\":\\"com.apple.mobilelogic\\",\\"installed\\":false,\\"running\\":false}]}"}]}}\n' "$id" ;;
              *'__adr001b_no_write_probe'*)
                refuse invalid_params ;;
              *'"command":"refresh_cache"'*)
                changed='[]'
                # `never_after_create`: once a marker exists the refreshes stop landing on the poller's
                # marker tick, so the cache keeps the create's own readback, readable and recent.
                if [ "$refresh_polls" = when_open ] || [ "$created" = false ]; then
                    poll_markers && changed='["markers"]'
                fi
                printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"State refresh completed via AX fallback poller."}],"structuredContent":{"operation":"system.refresh_cache","refreshed":true,"changed_sections":%s,"source":"ax_fallback_poller","message":"State refresh completed via AX fallback poller."}}}\n' "$id" "$changed" ;;
              *'"uri":"logic://markers"'*)
                readable=$(cat cache-readable); epoch=$(cat cache-epoch)
                if [ "$epoch" = null ]; then fetched=null; age=null
                else fetched="\\\"$(iso_of "$epoch")\\\""; age=$(age_of "$epoch"); fi
                if [ "$readable" = true ]; then source=ax_live; extra=
                elif [ -s cache ]; then source=cache; extra="\\\"reason\\\":\\\"marker_list_not_open\\\","
                else source=unreadable; extra="\\\"reason\\\":\\\"marker_list_not_open\\\","; fi
                if [ "$readable" = true ] && [ ! -s cache ]; then empty=true; else empty=false; fi
                printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://markers","text":"{\\"cache_age_sec\\":%s,\\"fetched_at\\":%s,\\"ax_occluded\\":false,%s\\"readable\\":%s,\\"source\\":\\"%s\\",\\"verified_empty\\":%s,\\"data\\":[%s]}"}]}}\n' "$id" "$age" "$fetched" "$extra" "$readable" "$source" "$empty" "$(rows_json cache)" ;;
              *'"uri":"logic://transport/state"'*)
                shape_source=ax_live; shape_unverified=; shape_value="$(cat bar).$(cat beat).1.1"
                shape_components='[\"bar\",\"beat\",\"subdivision\",\"tick\"]'
                case "$transport_shape" in
                  cache) shape_source=cache; shape_unverified='\"unverified\":true,' ;;
                  unverified) shape_unverified='\"unverified\":true,' ;;
                  prefix) shape_value="$(cat bar).$(cat beat)"; shape_components='[\"bar\",\"beat\"]' ;;
                esac
                # The display mode decides how much of the position the control bar shows: Logic's
                # default Beats & Project shows bar and beat, Beats shows all four.
                if [ -f display-mode ] && [ "$(cat display-mode)" != Beats ]; then
                    shape_value="$(cat bar).$(cat beat)"; shape_components='[\"bar\",\"beat\"]'
                fi
                if [ "$default_position" = true ]; then readback_json=
                else readback_json=",\\\"positionReadback\\\":{\\\"value\\\":\\\"$shape_value\\\",\\\"observedComponents\\\":$shape_components}"; fi
                printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://transport/state","text":"{\\"source\\":\\"%s\\",%s\\"cache_age_sec\\":0,\\"data\\":{\\"state\\":{\\"isPlaying\\":false,\\"isRecording\\":false,\\"tempo\\":120,\\"position\\":\\"%s\\"%s}}}"}]}}\n' "$id" "$shape_source" "$shape_unverified" "$shape_value" "$readback_json" ;;
              *'"command":"create_marker"'*)
                created=true
                open_list
                name=$(param_string name)
                at="$(cat bar).1.1.1"
                if [ "$name_applies" != true ] || [ -z "$name" ]; then name="Marker $(($(/usr/bin/wc -l < live) + 1))"; fi
                printf '%s|%s\n' "$name" "$at" >> live
                /usr/bin/sort -s -t'|' -k2,2n live -o live
                printf 'create %s|%s\n' "$name" "$at" >> writes
                # The dispatcher reads the open list before and after its create and caches that read.
                poll_markers
                if [ "$close_after_create" = true ]; then opened=true; fi
                release_list
                ok ;;
              *'"command":"delete_marker"'*)
                open_list
                index=$(param_int index); row=
                [ -n "$index" ] && row=$(/usr/bin/sed -n "$((index + 1))p" live)
                if [ -n "$row" ]; then
                    /usr/bin/sed -i '' "$((index + 1))d" live
                    printf 'delete %s %s\n' "$index" "$row" >> writes
                    if [ "$ghost_polls" -gt 0 ]; then printf '%s\n' "$row" > ghost; echo "$ghost_polls" > ghost-left; fi
                    ok
                else refuse element_not_found; fi
                release_list ;;
              *'"command":"rename_marker"'*)
                open_list
                index=$(param_int index); name=$(param_string name); row=
                [ -n "$index" ] && row=$(/usr/bin/sed -n "$((index + 1))p" live)
                if [ -n "$row" ] && [ -n "$name" ]; then
                    /usr/bin/awk -v n="$((index + 1))" -v name="$name" 'BEGIN { FS = OFS = "|" } NR == n { $1 = name } { print }' live > live.next && mv live.next live
                    printf 'rename %s %s -> %s\n' "$index" "$row" "$name" >> writes
                    ok
                else refuse element_not_found; fi
                release_list ;;
              *'"command":"goto_bar"'*|*'"command":"goto_position"'*)
                to=$(param_int bar); by_position=false
                if [ -n "$to" ]; then
                    if [ "$bar_overshoot" = true ]; then to=$((to + 1)); bar_overshoot=false; fi
                    printf 'goto_bar %s\n' "$to" >> writes
                    echo 1 > beat
                else
                    if [ "$refuse_goto_position" = true ]; then refuse write_refused; continue; fi
                    at=$(param_string position)
                    to=${at%%.*}
                    rest=${at#*.}
                    printf 'goto_position %s\n' "$at" >> writes
                    echo "${rest%%.*}" > beat
                    by_position=true
                fi
                printf '%s\n' "$to" > bar
                if [ "$by_position" = true ] && [ "$goto_reply" != ok ]; then
                    submitted='\"state\":\"B\",\"success\":true,\"verified\":false,\"reason\":\"readback_unavailable\",\"requested\":\"'$at'\",\"via\":\"dialog\",\"dialog_cleanup\":\"closed\",\"dialog_submission_attempted\":true,\"write_attempted\":true,\"menu_actuation_attempted\":true,\"verification_source\":\"transport_state\"'
                    # `finalizeGotoPositionResult` marks a failed POST-write read with
                    # `post_write_readback: unavailable`. A failed PRE-write read with a matching
                    # post-write read carries `observed` and `verification_withheld` instead.
                    if [ "$goto_reply" = submitted_prewrite_failed ]; then
                        submitted=$submitted',\"verification_withheld\":\"observed_effect_unavailable\",\"observed\":\"'$at'\"'
                    else
                        submitted=$submitted',\"post_write_readback\":\"unavailable\"'
                    fi
                    if [ "$goto_reply" = submitted_unknown ]; then
                        submitted='\"state\":\"B\",\"success\":true,\"verified\":false,\"reason\":\"readback_unavailable\",\"operation\":\"transport.goto_position\",\"method\":\"dialog\",\"dialog_cleanup\":\"unobserved\",\"dialog_submission_indeterminate\":true,\"dialog_input_target\":\"unknown\",\"fallback_unsafe\":true,\"terminal\":true,\"safe_to_retry\":false,\"verification_source\":\"transport_state\"'
                    fi
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"isError":true,"content":[{"type":"text","text":"{%s}"}]}}\n' "$id" "$submitted"
                    continue
                fi
                ok ;;
              *'"command":"goto_marker"'*)
                # The product resolves a marker name against its cached list.
                name=$(param_string name)
                row=$(/usr/bin/grep "^$name|" cache | /usr/bin/head -1)
                if [ -n "$row" ]; then at=${row#*|}; printf '%s\n' "${at%%.*}" > bar; echo 1 > beat; ok
                else refuse element_not_found; fi ;;
              *) refuse unsupported_by_fixture ;;
            esac
        done
        """#
    }

    private func drive(
        _ fixture: Fixture, _ operation: OperationID, display: QualificationPositionDisplay? = nil
    ) throws -> QualificationOperationResult? {
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(
            uiObserver: unchangedUIForTests, positionDisplay: display, handshakeTimeout: 2,
            requestTimeout: 2, shutdownGrace: 2, uiSettleSleep: { _ in }
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))
        return result.operationResults[operation.rawValue]
    }

    /// What the drive sent to the server double, minus the display-mode double's own entries.
    private func sentRequests(_ fixture: Fixture) -> [String] {
        fixture.lines("requests").filter { !$0.contains("\"display_mode\"") }
    }

    private func driveOperations(
        _ fixture: Fixture, _ operations: [OperationID], display: QualificationPositionDisplay
    ) throws -> Result<QualificationDriveResult, Error> {
        let specs = try operations.map { operation in
            try #require(OperationRegistry.specs.first { $0.id == operation })
        }
        do {
            return .success(try QualificationTransport(
                uiObserver: unchangedUIForTests, positionDisplay: display, handshakeTimeout: 2,
                requestTimeout: 2, shutdownGrace: 2, uiSettleSleep: { _ in }
            ).drive(.init(
                executableURL: fixture.executableURL, environment: ["HANDSHAKE_DELAY": "0"],
                expectedOperationCount: 0, operations: specs)))
        } catch {
            return .failure(error)
        }
    }

    /// The canonical gate state: the Marker List is closed, so the passive marker read is the
    /// cache, unreadable. No recipe may stage a marker (or park the playhead for one) on that.
    @Test(arguments: markerOperations)
    func aClosedMarkerListRefusesBeforeAnythingIsStaged(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: false)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")

        #expect(fixture.live == Self.originals, "every original marker survives: \(fixture.writes)")
        #expect(fixture.writes.isEmpty, "nothing is staged on an unreadable marker read: \(fixture.writes)")
        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("fresh"), "\(refusal)")
    }

    /// The list was open and readable when the recipe began, and closed once a marker was staged —
    /// what an operation that closes the list it opened leaves behind. The cache then still holds
    /// the probe at index 0. Cleanup must not delete on those rows.
    @Test(arguments: markerOperations)
    func aListThatClosesAfterStagingNeverLetsCleanupDeleteByStaleRows(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, closeAfterCreate: true)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")

        #expect(Self.originals.allSatisfy(fixture.live.contains),
                "every original marker survives: live \(fixture.live), writes \(fixture.writes)")
        #expect(!fixture.writes.contains { $0.hasPrefix("delete") }, "no delete without a fresh read: \(fixture.writes)")
        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("withheld"), "the leftover probe is named: \(refusal)")
    }

    /// The cache can also be READABLE and recent and still predate the read: the create's own
    /// readback lands in it, and a refresh that misses the poller's marker tick leaves it there.
    @Test func aReadableCacheThatPredatesTheReadIsNotFresh() throws {
        let fixture = try Fixture(
            listOpenInitially: true, closeAfterCreate: true, refreshPolls: "never_after_create")
        defer { fixture.remove() }
        let observed = try drive(fixture, .navigateCreateMarker)
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")

        #expect(Self.originals.allSatisfy(fixture.live.contains),
                "every original marker survives: live \(fixture.live), writes \(fixture.writes)")
        #expect(!fixture.writes.contains { $0.hasPrefix("delete") }, "no delete without a fresh read: \(fixture.writes)")
        #expect(observed?.mutationRestore == nil)
    }

    /// Logic's list settles slowly after a delete: it keeps showing the deleted probe, freshly read,
    /// for longer than the disappearance wait. A cleanup that took those rows as a reason to delete
    /// again sent its next delete at index 0, which was by then the user's marker. Once a delete's
    /// effect is unconfirmed, no further delete may be sent.
    @Test(arguments: markerOperations)
    func aDeleteWhoseDisappearanceNeverSettlesIsNotFollowedByAnother(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, ghostPolls: 8)
        defer { fixture.remove() }
        _ = try drive(fixture, operation)
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")

        #expect(Self.originals.allSatisfy(fixture.live.contains),
                "every original marker survives: live \(fixture.live), writes \(fixture.writes)")
        let foreignDeletes = fixture.writes.filter {
            $0.hasPrefix("delete") && !$0.contains("qualification_phase_b")
        }
        #expect(foreignDeletes.isEmpty, "only the probe is ever deleted: \(fixture.writes)")
    }

    /// The playhead recipes (`navigate.goto_bar`, `transport.goto_position`) refuse when the move
    /// does not read back as requested, and that refusal used to leave the playhead where the
    /// mutation put it. Every exit after a move puts it back, verified by a read.
    @Test(arguments: [OperationID.navigateGotoBar, .transportGotoPosition])
    func aPlayheadCycleThatRefusesAfterMovingPutsThePlayheadBack(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, barWriteOvershoot: true)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(observed?.mutationRestore == nil, "the overshoot must refuse the cycle: \(fixture.writes)")
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")
    }

    /// Positive control: a list that stays open gives fresh reads throughout, and the cycle stages,
    /// exercises, restores and removes its own marker by name.
    @Test(arguments: markerOperations)
    func aListThatStaysOpenCompletesTheCycleAndRemovesTheProbe(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)
        #expect(fixture.bar == 1, "the playhead is back where it started: bar \(fixture.bar.map(String.init) ?? "unread"), writes \(fixture.writes)")

        #expect(fixture.live == Self.originals, "live \(fixture.live), writes \(fixture.writes)")
        #expect(observed?.mutationRestore != nil, "\(observed?.mutationRestoreRefusal ?? "no refusal")")
        #expect(observed?.mutationRestoreRefusal == nil)
    }

    /// The cycle's own return is a `goto_bar`, which lands on a bar's first beat. From a start off
    /// that beat the exact origin is put back by a `goto_position` — and when that is refused the
    /// playhead is left at 1.1, a position this cycle never started from. The refusal must reach
    /// the caller, and no cycle record may be kept.
    @Test func aRefusedExactOriginMoveAfterTheBarReturnIsNotACredit() throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, refuseGotoPosition: true)
        defer { fixture.remove() }
        let observed = try drive(fixture, .navigateGotoMarker)

        #expect(observed?.mutationRestore == nil, "a playhead left off its origin earns no cycle record: \(fixture.writes)")
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("playhead"), "the failed restore is named: \(refusal)")
        #expect(fixture.live == Self.originals, "the probe is still removed: live \(fixture.live), writes \(fixture.writes)")
    }

    /// Positive control for the case above: the same start off the bar's first beat, with the exact
    /// move accepted, completes the cycle and leaves the playhead where it started.
    @Test func anExactOriginMoveAfterTheBarReturnCompletesTheCycle() throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2)
        defer { fixture.remove() }
        let observed = try drive(fixture, .navigateGotoMarker)

        #expect(observed?.mutationRestore != nil, "\(observed?.mutationRestoreRefusal ?? "no refusal")")
        #expect(fixture.bar == 1 && fixture.beat == 2, "the playhead is back at 1.2: bar \(fixture.bar.map(String.init) ?? "unread") beat \(fixture.beat.map(String.init) ?? "unread")")
        #expect(fixture.live == Self.originals, "live \(fixture.live), writes \(fixture.writes)")
    }

    /// With the position controls unreadable the resource publishes the display default `1.1.1.1`
    /// and no `positionReadback`. That is no origin: the marker and bar recipes refuse before the
    /// first position-changing call.
    @Test(arguments: [OperationID.navigateGotoMarker])
    func aDefaultPositionWithNoReadbackIsRefusedBeforeTheFirstMove(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, defaultPosition: true)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("position"), "the unreadable origin is named: \(refusal)")
        let moves = fixture.writes.filter { $0.contains("goto_bar") || $0.contains("goto_position") || $0.hasPrefix("create") }
        #expect(moves.isEmpty, "nothing moved or created: \(fixture.writes)")
    }

    /// The origin must come from a live, verified read. When the live read fails the resource answers
    /// from its cache, `unverified: true`, and that snapshot can still carry a complete readback of
    /// where the playhead WAS. A readback that stops at bar and beat is no better: the recipe could
    /// not put the subdivision and tick back. Each is refused before the first move.
    @Test(arguments: [OperationID.navigateGotoMarker, .navigateGotoBar, .transportGotoPosition],
          ["cache", "unverified", "prefix"])
    func anOriginThatIsNotALiveVerifiedFullReadbackIsRefusedBeforeTheFirstMove(
        operation: OperationID, shape: String
    ) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, transportShape: shape)
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("position"), "the unreadable origin is named: \(refusal)")
        let moves = fixture.writes.filter { $0.contains("goto_bar") || $0.contains("goto_position") || $0.hasPrefix("create") }
        #expect(moves.isEmpty, "nothing moved or created: \(fixture.writes)")
        #expect(fixture.bar == 1 && fixture.beat == 2, "the playhead did not move: \(fixture.writes)")
    }

    // MARK: State B: the dialog submitted, the dispatcher's immediate read failed

    static let playheadOperations: [OperationID] = [.navigateGotoMarker, .navigateGotoBar, .transportGotoPosition]

    /// Go To Position can submit and close its dialog and the dispatcher's own read can then fail:
    /// State B, `isError`, `dialog_submission_attempted`. The playhead landed; the independent exact
    /// readback decides the restore, so the cycle is credited and the playhead is where it started.
    @Test(arguments: playheadOperations)
    func aSubmittedDialogWhoseImmediateReadFailedIsDecidedByTheExactReadback(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, gotoReply: "submitted_read_failed")
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(fixture.writes.contains { $0.hasPrefix("goto_position") }, "the exact restore was attempted: \(fixture.writes)")
        #expect(observed?.mutationRestore != nil, "\(observed?.mutationRestoreRefusal ?? "no refusal")")
        #expect(fixture.bar == 1 && fixture.beat == 2, "bar \(fixture.bar.map(String.init) ?? "unread") beat \(fixture.beat.map(String.init) ?? "unread")")
        #expect(fixture.live == Self.originals, "live \(fixture.live), writes \(fixture.writes)")
    }

    /// An error reply that does not prove the submission stays a failed restore although the playhead
    /// then reads back exactly.
    @Test(arguments: playheadOperations)
    func anErrorReplyWithAnIndeterminateSubmissionIsStillAFailedRestore(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, gotoReply: "submitted_unknown")
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(fixture.writes.contains { $0.hasPrefix("goto_position") }, "the exact restore was attempted: \(fixture.writes)")
        #expect(observed?.mutationRestore == nil, "a restore the server did not confirm earns no cycle record")
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("playhead"), "the failed restore is named: \(refusal)")
    }

    // MARK: Display mode: Logic's default shows bar and beat only

    static let displayOrder: [OperationID: String] = [
        .navigateGotoMarker: "goto_marker", .navigateGotoBar: "goto_bar", .transportGotoPosition: "goto_position",
    ]

    /// Logic's default control bar is Beats & Project, which publishes bar and beat, so every
    /// marker and bar cycle used to refuse. The cycle reads the mode, switches to Beats, confirms,
    /// captures the origin, runs, puts the playhead back and verifies it while still in Beats, and
    /// only then gives the mode back and reads it again.
    @Test(arguments: playheadOperations)
    func aBeatsAndProjectStartIsSwitchedToBeatsAndGivenBackAfterThePlayheadIsRestored(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject)
        let observed = try drive(fixture, operation, display: fake.display)

        #expect(observed?.mutationRestore != nil, "\(observed?.mutationRestoreRefusal ?? "no refusal")")
        let events = QualificationPositionDisplayFake.events(in: fixture.directory)
        let beatsAndProject = "mode_read=Beats & Project"
        let command = Self.displayOrder[operation] ?? "?"
        #expect(QualificationPositionDisplayFake.containsInOrder([
            beatsAndProject, "mode_switch", "mode_read=Beats", "transport_read", command,
            "goto_position", "transport_read", "mode_restore", beatsAndProject,
        ], in: events), "\(events)")
        #expect(QualificationPositionDisplayFake.closingModeCalls(in: events) == ["mode_restore", beatsAndProject], "\(events)")
        #expect(fake.mode == QualificationPositionDisplayFake.beatsAndProject)
        #expect(fixture.bar == 1 && fixture.beat == 2, "bar \(fixture.bar.map(String.init) ?? "unread") beat \(fixture.beat.map(String.init) ?? "unread")")
        #expect(fixture.live == Self.originals, "live \(fixture.live), writes \(fixture.writes)")
    }

    /// A mode that cannot be read, a switch that cannot be performed, and a switch that reports
    /// itself done without changing the mode stop the cycle before it stages or moves anything.
    @Test(arguments: playheadOperations,
          [QualificationPositionDisplayFake.Fault.unreadable, .switchUnavailable, .switchNotApplied])
    func aModeThatCannotBeReadOrSwitchedToBeatsStartsNothing(
        operation: OperationID, fault: QualificationPositionDisplayFake.Fault
    ) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject, fault: fault)
        let observed = try drive(fixture, operation, display: fake.display)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("display mode"), "\(refusal)")
        #expect(fixture.writes.isEmpty, "nothing moved or created: \(fixture.writes)")
        #expect(fixture.bar == 1 && fixture.beat == 2)
    }

    /// The four-component origin cannot be captured even in Beats: nothing starts and the mode is
    /// still given back.
    @Test(arguments: playheadOperations)
    func anOriginThatCannotBeCapturedInBeatsStillGivesTheModeBack(operation: OperationID) throws {
        let fixture = try Fixture(
            listOpenInitially: true, startBeat: 2, transportShape: "prefix", displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject)
        let observed = try drive(fixture, operation, display: fake.display)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("position"), "the unreadable origin is named: \(refusal)")
        #expect(fixture.writes.isEmpty, "nothing moved or created: \(fixture.writes)")
        let events = QualificationPositionDisplayFake.events(in: fixture.directory)
        #expect(QualificationPositionDisplayFake.closingModeCalls(in: events) == ["mode_restore", "mode_read=Beats & Project"], "\(events)")
        #expect(fake.mode == QualificationPositionDisplayFake.beatsAndProject)
    }

    /// A mode that is not confirmed restored is never a credited cycle, although the marker is
    /// removed and the playhead is back where it started.
    @Test(arguments: playheadOperations,
          [QualificationPositionDisplayFake.Fault.restoreRefused, .restoreNotApplied])
    func aDisplayModeThatIsNotConfirmedRestoredIsNotRecordedAsSuccess(
        operation: OperationID, fault: QualificationPositionDisplayFake.Fault
    ) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject, fault: fault)
        // The drive ends with `recoveryUnconfirmed`: no result exists, so no cycle record is earned.
        guard case .failure(let error) = try driveOperations(fixture, [operation], display: fake.display) else {
            Issue.record("the drive returned a result although the display mode was not confirmed back")
            return
        }
        let transportError = try #require(error as? QualificationTransportError, "\(error)")
        #expect(transportError.requiresDriveAbort, "\(transportError)")
        #expect("\(transportError)".contains("display mode"), "\(transportError)")
        let events = QualificationPositionDisplayFake.events(in: fixture.directory)
        #expect(QualificationPositionDisplayFake.containsInOrder(
            ["mode_switch", "goto_position", "transport_read", "mode_restore"], in: events),
            "the playhead is restored and verified before the mode: \(events)")
        #expect(fixture.bar == 1 && fixture.beat == 2)
        #expect(fixture.live == Self.originals, "live \(fixture.live), writes \(fixture.writes)")
    }

    /// The marker and playhead cycles hold Beats for the whole cycle and get no recovery witness of
    /// their own. A mode that is not confirmed given back still ends the drive: the next operation
    /// sends nothing, so its requests are exactly those of the first operation alone, and the bar
    /// is never recorded as the "original" of a later cycle.
    @Test(arguments: playheadOperations,
          [QualificationPositionDisplayFake.Fault.restoreRefused, .restoreNotApplied, .switchUnsettledNoLease])
    func aDisplayModeNotConfirmedBackEndsTheDriveBeforeTheNextOperationIsSent(
        operation: OperationID, fault: QualificationPositionDisplayFake.Fault
    ) throws {
        let next: OperationID = operation == .navigateGotoBar ? .transportGotoPosition : .navigateGotoBar
        func run(_ operations: [OperationID]) throws -> (outcome: Result<QualificationDriveResult, Error>, sent: [String], mode: String) {
            let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats & Project")
            defer { fixture.remove() }
            let fake = try QualificationPositionDisplayFake(
                directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject, fault: fault)
            let outcome = try driveOperations(fixture, operations, display: fake.display)
            return (outcome, sentRequests(fixture), fake.mode)
        }
        let alone = try run([operation])
        let both = try run([operation, next])
        for result in [alone, both] {
            guard case .failure(let error) = result.outcome else {
                Issue.record("the drive went on after the display mode was not confirmed back: \(result.sent)")
                return
            }
            let transportError = try #require(error as? QualificationTransportError, "\(error)")
            #expect(transportError.requiresDriveAbort, "\(transportError)")
            #expect("\(transportError)".contains("display mode"), "\(transportError)")
        }
        #expect(both.sent == alone.sent, "nothing is sent for the next operation: \(both.sent)")
        // A switch that left no lease stops before the first request of the cycle: nothing at all.
        #expect(fault == .switchUnsettledNoLease ? both.sent.isEmpty : !both.sent.isEmpty, "\(both.sent)")
    }

    /// The abort of a display mode that is not confirmed back carries the cleanup the recipe had
    /// completed: the staged marker whose deletion was withheld is named in the abort itself, and
    /// nothing is sent after it.
    @Test func aDisplayModeAbortCarriesTheNamedResidualMarker() throws {
        func run(_ operations: [OperationID]) throws -> (detail: String, sent: [String]) {
            let fixture = try Fixture(
                listOpenInitially: true, closeAfterCreate: true, startBeat: 2, displayMode: "Beats & Project")
            defer { fixture.remove() }
            let fake = try QualificationPositionDisplayFake(
                directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject,
                fault: .restoreRefused)
            let outcome = try driveOperations(fixture, operations, display: fake.display)
            guard case .failure(let error) = outcome,
                  case QualificationTransportError.recoveryUnconfirmed(let detail)? = error as? QualificationTransportError
            else {
                Issue.record("expected recoveryUnconfirmed, got \(outcome)"); return ("", [])
            }
            return (detail, sentRequests(fixture))
        }
        let alone = try run([.navigateGotoMarker])
        let both = try run([.navigateGotoMarker, .navigateGotoBar])
        for result in [alone, both] {
            #expect(result.detail.contains("display mode"), "\(result.detail)")
            #expect(result.detail.contains("withheld") && result.detail.contains("qualification_phase_b_probe"),
                    "the residual marker is named in the abort: \(result.detail)")
        }
        #expect(!alone.sent.isEmpty && both.sent == alone.sent, "nothing is sent after the abort: \(both.sent)")
    }

    /// The same for the playhead cycle: the abort carries the cleanup the recipe completed.
    @Test(arguments: [OperationID.navigateGotoBar, .transportGotoPosition])
    func aDisplayModeAbortCarriesThePlayheadCleanup(operation: OperationID) throws {
        let fixture = try Fixture(
            listOpenInitially: true, barWriteOvershoot: true, startBeat: 2, displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject,
            fault: .restoreRefused)
        let outcome = try driveOperations(fixture, [operation], display: fake.display)
        guard case .failure(let error) = outcome else {
            Issue.record("the drive returned a result"); return
        }
        guard case QualificationTransportError.recoveryUnconfirmed(let detail)? = error as? QualificationTransportError else {
            Issue.record("expected recoveryUnconfirmed, got \(error)"); return
        }
        #expect(detail.contains("display mode"), "\(detail)")
        #expect(detail.contains("cleanup:") && !detail.contains("cleanup did not run"),
                "the completed playhead cleanup is carried: \(detail)")
    }

    // MARK: Round 5: one setting read two ways, a read that only half failed

    /// B. The dispatcher's PRE-write read failed and the POST-write read worked: `observed` and
    /// `verification_withheld: observed_effect_unavailable`, no `post_write_readback`. The landing was
    /// read, so there is nothing for a follow-up to decide; the seek is a failed restore.
    @Test(arguments: playheadOperations)
    func aSubmittedDialogWhoseOnlyPreWriteReadFailedIsNotDecidedByTheFollowUp(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, gotoReply: "submitted_prewrite_failed")
        defer { fixture.remove() }
        let observed = try drive(fixture, operation)

        #expect(fixture.writes.contains { $0.hasPrefix("goto_position") }, "the exact restore was attempted: \(fixture.writes)")
        #expect(observed?.mutationRestore == nil, "a restore the server did not confirm earns no cycle record")
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("playhead"), "the failed restore is named: \(refusal)")
    }

    /// v-1. Already in Beats: nothing is switched, so nothing is restored, but the mode is read
    /// again before the cycle is credited. A mode that changed or stopped reading is a failure, and
    /// the change is not overwritten.
    @Test(arguments: playheadOperations,
          [QualificationPositionDisplayFake.Fault.changedByOthersAfterFirstRead, .unreadableAfterFirstRead])
    func aBeatsStartWhoseModeChangesOrStopsReadingIsNotRecordedAsSuccess(
        operation: OperationID, fault: QualificationPositionDisplayFake.Fault
    ) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beats, fault: fault)
        let observed = try drive(fixture, operation, display: fake.display)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("display mode"), "\(refusal)")
        let events = QualificationPositionDisplayFake.events(in: fixture.directory)
        #expect(!events.contains("mode_switch") && !events.contains("mode_restore"),
                "this call never switched, so it never writes the mode: \(events)")
        #expect(fake.mode == QualificationPositionDisplayFake.beats)
    }

    /// v-3. The popup says Beats & Project and the checked item says Time & Project: nothing is
    /// switched, moved or created.
    @Test(arguments: playheadOperations)
    func aPopupTitleThatDisagreesWithTheCheckedItemStartsNothing(operation: OperationID) throws {
        let fixture = try Fixture(listOpenInitially: true, startBeat: 2, displayMode: "Beats & Project")
        defer { fixture.remove() }
        let fake = try QualificationPositionDisplayFake(
            directory: fixture.directory, start: QualificationPositionDisplayFake.beatsAndProject,
            fault: .checkedItemConflicts)
        let observed = try drive(fixture, operation, display: fake.display)

        #expect(observed?.mutationRestore == nil)
        let refusal: String = observed?.mutationRestoreRefusal ?? "no refusal"
        #expect(refusal.contains("display mode"), "\(refusal)")
        let events = QualificationPositionDisplayFake.events(in: fixture.directory)
        #expect(!events.contains("mode_switch") && !events.contains("mode_restore"), "\(events)")
        #expect(fixture.writes.isEmpty, "nothing moved or created: \(fixture.writes)")
        #expect(fixture.bar == 1 && fixture.beat == 2)
        #expect(fake.mode == QualificationPositionDisplayFake.beatsAndProject)
    }
}
