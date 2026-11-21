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
            refuseGotoPosition: Bool = false
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
            try Data(script.utf8).write(to: executableURL)
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
                printf '{"jsonrpc":"2.0","id":%s,"result":{"contents":[{"uri":"logic://transport/state","text":"{\\"source\\":\\"ax_live\\",\\"cache_age_sec\\":0,\\"data\\":{\\"state\\":{\\"isPlaying\\":false,\\"isRecording\\":false,\\"tempo\\":120,\\"position\\":\\"%s.%s.1.1\\"}}}"}]}}\n' "$id" "$(cat bar)" "$(cat beat)" ;;
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
                to=$(param_int bar)
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
                fi
                printf '%s\n' "$to" > bar
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

    private func drive(_ fixture: Fixture, _ operation: OperationID) throws -> QualificationOperationResult? {
        let spec = try #require(OperationRegistry.specs.first { $0.id == operation })
        let result = try QualificationTransport(
            uiObserver: unchangedUIForTests, handshakeTimeout: 2, requestTimeout: 2, shutdownGrace: 2
        ).drive(.init(
            executableURL: fixture.executableURL,
            environment: ["HANDSHAKE_DELAY": "0"],
            expectedOperationCount: 0,
            operations: [spec]))
        return result.operationResults[operation.rawValue]
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
}
