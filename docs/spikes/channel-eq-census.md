# Channel EQ AX Parameter Census

**Status: GATE FAILED (2026-07-07) — registry activation honest-deferred.** Scaffold ships; no production Channel EQ verified param is activated.

Source script: `Scripts/spike-channel-eq-census.py`
Enumerator: `logic_plugins.get_inventory` for insert-slot readback, then read-only System Events AX crawl of the open Channel EQ editor window.

## Run Metadata

- Date: 2026-07-07
- Logic Pro version: 12.x (server baseline 3.8.0)
- macOS: Retina 1920×1080 logical
- System locale: Korean; Logic UI language: English
- Project: `~/Music/Logic/Untitled 54.logicx` (scratch)
- Track index: 1 (Audio 1); Insert index: 0
- Probe command: `python3 Scripts/spike-channel-eq-census.py`

## What WORKS (verified live)

- **`logic_plugins.insert_verified "Channel EQ"` → State A.** Inserted `logic.stock.effect.channel_eq` at slot 0 via `ax_exact_slot_popup`, verified by `ax_plugin_inventory` (this is the existing shipped verified-insert path — solid).
- Plugin editor opens as an `AXDialog` window titled by track name (`Audio 1`), with 15 top-level UI elements including a **View menu** (`AXMenuButton` desc=`view`) offering **`Controls`** and **`Editor`** view modes.

## The wall (why parameter census + registry activation is deferred)

> **2026-09-04 — the instrument behind the next two readings was broken (#767).** `entire
> contents` returns an empty list, without raising, for all ten applications tried here: 0 for a
> Logic window where a manual descent of the same window finds 464 elements, and 0 for nine other
> applications. An empty result from it is not a reading. **Both bullets below cite exactly that
> as their evidence, so their support is void** — which does not make their conclusions false, only
> unevidenced. Re-measure with an explicit descent before citing them. Worth noting while you do:
> `plugins.set_eq_band_verified` shipped in ADR-013 with all 24 named band parameters, which sits
> oddly beside "no per-band `AXSlider` exposed".

The Channel EQ **parameter controls are not reachable through standard AX traversal** in either view mode:

- ~~**Editor (graphical) view**: parameters are drawn on a custom `AXGroup` (desc=`EQ`) canvas — no per-band `AXSlider`/`AXValueIndicator` exposed. `entire contents` of the window filtered for slider/value roles = empty.~~ **REFUTED 2026-09-04 (#767).** The reading was the instrument, not the plug-in: `entire contents` returns an empty list without raising for all ten applications it was tried on here. A manual descent of the same `AXDialog`, seconds apart in the same process, finds **70 elements and 26 `AXSlider`s** (25 distinct names — two are called `Gain`) — `Low Cut Frequency/Order/Q`, `Low Shelf F/G/Q`, `Peak 1`–`Peak 4` F/G/Q, `High Shelf F/G/Q`, `High Cut F/Order/Q`, `Gain` — each with a raw `AXValue` and a rendered `AXValueDescription` (`«42.2 Hz»`, `«+2.2 dB»`, `«18 dB/Oct»`). **One of them** was also shown to be actuable, and not by setting: an `AXValue` write on `Peak 1 Gain` moves the control one step toward the requested value and returns success, so reaching a value is a bounded convergence loop with a readback between iterations (six writes of `before + 20` walked 262 → 268; six writes of `before` restored it exactly). The other 25 were read, not written — `AXValue` settability was checked on that one slider only, so "the parameters are actuable" is not yet a statement this measurement supports. **This is specific to Channel EQ, and the sliders being NAMED is the specific part.** Two other editors opened back to back on the same strip expose zero sliders — ChromaVerb (21 elements) and the Studio Grand instrument (29) — so the sentence above is wrong about the plug-in this document is named after and right about its neighbours. And this repository's own Compressor measurement records 22 sliders that are all described `슬라이더`, with the parameter names living in separate text fields — sliders without names, which cannot be paired to a parameter without positional identity. Four plug-ins, three behaviours. See `docs/observations/2026-09-04-channel-eq-parameters-are-readable.json`.
- ~~**Controls view**: switching via the View menu works, but `entire contents` of the plugin window then returns **0 elements** — the AU parameter view is a hosted/remote view opaque to host-process AX recursion (same opacity class as the out-of-process save panel in the T5 spike). The graphical `EQ` group is gone and no traversable slider tree replaces it.~~ **VOID AS WRITTEN 2026-09-04 (#767)**, same cause. A manual descent of Compressor's Controls view finds a 29-row table with 6 pop-ups, each honestly exposing its label and current value. That view does have a wall, and it is a different one: the pop-ups open under `AXShowMenu` but publish only the current choice, and one publishes three items with identical titles — so a choice cannot be requested by name. "Cannot see" and "can see, cannot name" are different findings and only the second one is true here.
- The existing shipped verified-param path only ever activated **one** parameter (Compressor `threshold`, a single earlier T0 spike; every other param fails closed with `unsupported_param_readback` — see `AccessibilityChannel+VerifiedPlugins.swift:509`). Channel EQ's per-band freq/gain/Q are not reachable by the same `AXSlider`-by-description mechanism.

Per PRD AC-6.1 the registry may only be filled from real census values (guessing AX ids/units/tolerances is explicitly forbidden). ~~Since the AX surface does not expose those values here, **no registry entry is activated.**~~ **The premise is gone (#767):** the surface does expose them, 26 of them, with names and rendered units. No registry entry is activated *yet* — that is now work waiting to be done rather than a wall, and it wants its own change with its own live evidence. The scaffold (census probe, inert TODO entries, test seam) ships ready for a future run on a build/host where the AU parameter view is AX-traversable, or via a different enumeration surface (e.g. an AU parameter API rather than the GUI).

## Parameter Census

~~Not obtainable in this environment (AU parameter view AX-opaque).~~ **Obtainable, measured 2026-09-04 (#767):** 26 named `AXSlider`s over 25 distinct descriptions, each with a raw `AXValue` and a rendered `AXValueDescription`. The table is still unfilled and AC-6.1/AC-6.3 still bind — what changed is that filling it from evidence is now possible, and doing so is a separate change with its own live run.

## Registry Decisions

- Production Channel EQ entries: **left inert (TODO)** — none activated.
- Unregistered Channel EQ params continue to fail closed with `unsupported_param_readback` (unchanged contract).

## Follow-up candidates (not this PR)

- Enumerate AU parameters via the AudioUnit parameter API (`AudioUnitGetProperty`/`kAudioUnitProperty_ParameterList`) instead of the GUI AX tree — would bypass the opaque hosted view entirely and is the most promising path to a real census.
- Investigate whether a specific Logic build or the "Controls" view exposes `AXSlider` descriptions on other hosts.

## rename_marker spike (AC-6.6) — DEFERRED

Same session probe: `logic_navigate.create_marker` did not surface a renamable marker in `logic://markers` (list read empty post-create; markers require the Marker global track / Marker List visible, and a verified rename needs a reliable AX text-edit path this environment has not demonstrated — cf. the goto-position "마디 slider not found" and save-panel keyboard-routing walls). rename_marker remains `not_implemented` (unchanged); no false capability advertised.
