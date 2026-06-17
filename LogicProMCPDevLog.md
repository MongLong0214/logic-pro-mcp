# LogicProMCP — Development log (fork)

Companion to [`CHANGELOG.md`](CHANGELOG.md). Tracks fork-specific work and field findings against live Logic Pro / macOS combinations as they're discovered. `CHANGELOG.md` remains the formal release history; this file captures the *narrative* — why a change was needed, what was diagnosed, what to watch for next.

---

## 2026-06-17 — Logic 12.2 / macOS 26 track-header AX matcher fix

**Branch:** `fix/logic-12.2-track-headers-ax`
**Affected resource:** `logic://tracks`
**Field environment:** Logic Pro 12.2 on macOS 26.3.1 (Apple Silicon)

### Symptom

`logic://tracks` returned synthesized placeholder rows even when the Mixer panel was visible and MCU was fully connected/registered:

```json
{
  "source": "ax_live_with_file_count",
  "data": [
    { "id": 0, "name": "Track 1", "placeholder": true, "type": "unknown", ... },
    ...
  ]
}
```

Mixer state was healthy (`mcu_connected: true`, `mcu_registered: true`, `data_source: "ax_poll"`, real strips with `plugins_source: "ax"`), so the Logic 12.2 mixer matcher landed in v3.4.5 was working. The parallel issue on the tracks side hadn't been addressed.

### Diagnosis

Per [`ResourceHandlers.swift:481`](Sources/LogicProMCP/Resources/ResourceHandlers.swift) (`readTracks`), Tier 1 only fires when `cache.getTracks()` is non-empty. The cache is populated by `StatePoller.pollTracks → AccessibilityChannel.execute("track.get_tracks") → runtime.tracks() → AXLogicProElements.getTrackHeaders()`. If `getTrackHeaders` returns `nil`, the AX response is empty, the cache stays empty, and the resource falls to Tier 2 placeholder synthesis from `MetaData.plist`'s `NumberOfTracks`.

Instrumented `getTrackHeaders` to dump the main-window AX tree once when all four existing strategies failed. The relevant element appeared as:

```
[6] role=AXGroup desc="Tracks header" children=10
```

(10 children matched the project's 10 tracks. The sibling `AXGroup desc="Tracks contents"` exposed each track's name embedded in `desc` as `Track N "Name"` — independent confirmation the right region was identified.)

Existing match at [`AXLogicProElements.swift:324`](Sources/LogicProMCP/Accessibility/AXLogicProElements.swift) (Strategy 3 — AXGroup-by-description):

```swift
return desc == "track headers" || desc == "트랙 헤더"
```

After `.lowercased()`, Logic 12.2's `"Tracks header"` becomes `"tracks header"`. Compared against `"track headers"`, that's a one-letter-plus-word-order drift: `tracks` (plural) vs `track` (singular), and `header` (singular) vs `headers` (plural). Pure string match, no structural change. None of the other three strategies (`AXList` with identifier `"Track Headers"`, `AXScrollArea` with identifier `"Tracks"`, AXOutline/AXTable with `AXLayoutItem` children) match the Logic 12.2 shape either, so `getTrackHeaders` returns `nil`.

### Fix

Expanded the Strategy 3 description match to accept all observed variants:

```swift
return desc == "track headers"
    || desc == "track header"
    || desc == "tracks header"   // Logic 12.2 + macOS 26 form
    || desc == "tracks headers"
    || desc == "트랙 헤더"
```

Same shape of fix the mixer matcher received in v3.4.5 ("Logic 12.2 mixer AX matcher restored — finds the Logic 12.2 mixer pane by role/description instead of the stale `identifier=='Mixer'` shape"). All four pre-existing strategies were preserved — no regression risk against older Logic builds or test fixtures that use the prior strings.

### Verification

After the patch:

```json
{
  "source": "ax_live",
  "data": [
    { "id": 0, "name": "Clean Echoes", "type": "unknown", ... },
    { "id": 5, "name": "lofi chorus",  "type": "unknown", ... },
    { "id": 9, "name": "Stereo Out",   "type": "master",  ... }
  ]
}
```

Real track names, `source: "ax_live"`, no `placeholder: true`, master bus correctly typed.

### Open follow-ups

- **Track type classification.** All non-master tracks still come back as `"type": "unknown"` on this combo. Likely a separate Logic 12.2 / macOS 26 description-string or role drift in whatever code path categorizes audio / aux / instrument tracks. Out of scope for this fix.
- **`Tracks contents` could be a richer secondary source.** The `AXGroup desc="Tracks contents"` sibling exposes per-track `AXLayoutArea` children whose `desc` is formatted as `Track N "Name"`. Could complement the current row-walk if header-walk ever degrades again. Not needed today, but worth noting.

### Files changed

- [`Sources/LogicProMCP/Accessibility/AXLogicProElements.swift`](Sources/LogicProMCP/Accessibility/AXLogicProElements.swift) — `getTrackHeaders()` Strategy 3 (AXGroup-by-description). Net +15 / −3 lines including the expanded comment block documenting the observed description-string variants.
