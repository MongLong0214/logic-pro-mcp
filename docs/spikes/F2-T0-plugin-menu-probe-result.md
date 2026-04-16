# T0 Spike Result: Plugin Menu AX Probe

**Date**: 2026-04-13 11:45 KST
**Environment**: macOS Darwin 25.3.0, Logic Pro 12.0.1, M-series Mac
**Probed plugin**: ES2 (loaded with "Acoustic Guitar" patch on instrument track)
**Scripts**:
- `Scripts/plugin-menu-ax-probe.swift` — initial probe (mistakenly targeted View-mode AXMenuButton)
- `Scripts/plugin-detective.swift` — full window dump (revealed real Setting role)
- `Scripts/setting-popup-probe.swift` — empirical menu navigation test (definitive)

---

## Q1. Does AXPress open the Setting menu?

**Empirical**:
- Setting dropdown is **`AXPopUpButton`** (NOT `AXMenuButton` as PRD §4.4 assumed)
- Position: `(670, 304)`, size `132×25`, value=`"기본 프리셋"` (Korean for "Default Preset")
- `AXUIElementPerformAction(popup, kAXPressAction)` returns **`-25204` (`.cannotComplete`)**
- **However the menu DOES open** — visually verified (35 items appeared, dismissable via `AXCancel`)
- Conclusion: AXPress on the Setting popup is **functionally inadequate** (returns failure code despite UI effect)
- **Recommended**: Use **CGEvent click at center of popup** (`LibraryAccessor.productionMouseClick`) for reliable popup-open

## Q2. Does AXPress on a submenu AXMenuItem populate children?

**Empirical**: ✅ **YES — 100% reliable**
- Press result `0` (`.success`) on every menu item tested
- Children populate within 200 ms settle
- 11 submenus observed with 5–33 children each (`01 Synth Leads`, `02 Synth Pads`, `03 Synth Bass`, …, `13 Warped Synth`)
- 24 top-level items are leaf/action (e.g. `설정`, `실행 취소`, `다음`, `이전`)
- Total top-level: **35 items** (11 hierarchical + 24 leaf/action)

## Q3. Empirical `submenuOpenDelayMs` floor

- `200 ms` settle reliable on ES2 (slowest observed)
- Recommended **default 250 ms** (with 100 ms floor); ceiling can stay 800 ms
- PRD assumption of 300 ms confirmed adequate

## Q4. Leaf-click auto-dismiss behavior

- **Cancel action** (`AXCancel` on menu) dismisses cleanly (result=0)
- Leaf click behavior to be re-tested when Set Preset is implemented; expected: Logic auto-dismisses on selection

## Q5. Plugin-window identity format

**Empirical**:
- `AXIdentifier` = **nil**
- `AXDescription` = **nil**
- `AXTitle` = **patch name** (e.g. "Acoustic Guitar"), NOT plugin bundle ID
- **Plugin name "ES2" exists as `AXStaticText`** within the plugin window at `(623, 375)`, value=`"ES2"`

**Identity strategy must change**:
- ❌ AXIdentifier / AXDescription → **unavailable**
- ⚠ AXTitle → patch name, not plugin name (misleading)
- ✅ **`AVAudioUnitComponent` / AU registry** keyed by track index → **only reliable identity**
- ✅ **AXStaticText scan within window** → can detect `"ES2"` for cross-validation

## Q6. Plugin-window appear within 2000 ms via slot double-click

- Not directly tested (plugin window was already open in this session)
- AC-5.4's 2000 ms timeout remains a safe upper bound

## Q7. Setting dropdown AXRole

- **`AXPopUpButton`** (NOT `AXMenuButton`)
- The single `AXMenuButton` in the plugin window is the **View-mode toggle** (Controls/Editor switcher), unrelated to presets

## Q8. Third-party AU support

- Not tested in this spike — Apple-only ES2. Best-effort per NG2.

---

## Verdict

**CHOSEN: MIXED**

- **Setting popup open**: **CGEvent click** at popup center via `LibraryAccessor.productionMouseClick(at:)` (popup AXPress returns `.cannotComplete` despite UI effect — unreliable)
- **Menu navigation** (submenu open + leaf click): **AXPress on AXMenuItem** (100% reliable, fast, deterministic)
- **Menu dismiss**: **AXCancel** on the menu element (verified)

## T1+ Design Implications

PRD v0.6 patches required:

1. **§4.1 architecture**: `findSettingDropdown` returns `AXPopUpButton`, not `AXMenuButton`. Heuristic: walk window children for `AXPopUpButton` whose value contains `"Preset"` / `"프리셋"` / `"Default"`.
2. **§4.4 Menu interaction row**: change from "Deferred to T0" to "MIXED — CGEvent for Setting popup open; AXPress for menu navigation". `productionMouseClickDelegate` closure on `PluginWindowRuntime` is **REQUIRED** (not conditional).
3. **§4.4 Plugin window identity row**: change from "AXIdentifier primary, AXDescription fallback, AXTitle last" to **"AU registry (track-index → instrument slot → bundle ID via `AVAudioUnitComponent`) primary; AXStaticText scan within window for plugin name secondary"**.
4. **§4.2 PluginPresetProbe.pressMenuItem closure**: signature stays path-based; internal routing now MIXED:
   - First hop (open Setting): CGEvent click via `productionMouseClickDelegate`
   - Subsequent hops (menu items): AXPress on AXMenuItem
5. **E11b severity**: Post-Event capability is now **REQUIRED** (CGEvent path is mandatory for popup open, not fallback). Upgrade severity P0 unconditional.
6. **§7.1 perf**: `submenuOpenDelayMs` floor lowered from 300 → 250 ms based on empirical finding.
7. **PluginInspector.swift T4 already-shipped methods**: `identifyPlugin` runtime closure must be implemented in T6 to query AU registry (NOT AX attributes), since Q5 confirmed AX identity attributes are nil.

## Empirical Counts (for ES2 reference)

- Top-level Setting menu items: **35** (11 hierarchical + 24 leaf/action)
- Hierarchical submenu sizes: 5, 6, 7, 11, 16, 18, 23, 24, 26, 27, 33 children
- Estimated total leaves: ~196 (if avg 17.8 leaves per submenu)

## Follow-ups

- Validate Alchemy submenu structure (deeper hierarchy expected) — defer to manual QA in T14.
- Re-test leaf-click auto-dismiss when T6/T8 lands the Set Preset path.
- Validate third-party AU plugin (e.g. Native Instruments) Setting menu coverage.
