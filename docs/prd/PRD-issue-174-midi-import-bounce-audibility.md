# PRD: Issue 174 MIDI Import Bounce Audibility Guard

**Version**: 0.1
**Author**: Product planning
**Date**: 2026-06-23
**Status**: Done
**Size**: S

---

## 1. Problem Statement

### 1.1 Background
Issue #174 reports a fresh demo where imported MIDI regions were visible and MCP readback showed 5 tracks / 5 regions, but the same-run Logic Bounce artifact was silent and rejected by audio analysis.

### 1.2 Problem Definition
Track and region readback alone must not be treated as export readiness for MIDI-backed software instrument content unless the session also has readable audible plugin/instrument evidence.

### 1.3 Impact of Not Solving
Demo/export tooling can spend time rendering a final artifact that is predictably silent, leaving the failure to a late audio guard rather than blocking before the Bounce dialog.

## 2. Goals & Non-Goals

### 2.1 Goals
- [x] G1: Project audit marks software-instrument tracks with regions but no readable plugin evidence as export blockers.
- [x] G2: `logic_project.bounce` preflight inherits the blocker through existing export readiness handling.
- [x] G3: Existing audio/external-MIDI bounce readiness behavior remains unchanged.

### 2.2 Non-Goals
- NG1: Automatically load or mutate instruments during bounce.
- NG2: Replace post-bounce audio analysis.
- NG3: Infer audibility from track/region counts alone.

## 3. User Stories & Acceptance Criteria

### US-1: Fail Before Silent Bounce
**As a** demo/export runner, **I want** MIDI-backed software-instrument regions without readable audible plugin evidence to block export readiness, **so that** a likely silent bounce is refused before rendering.

**Acceptance Criteria:**
- [x] AC-1.1: Given a software-instrument track with regions and no plugin evidence, when project audit runs, then it emits a blocker finding.
- [x] AC-1.2: Given the blocker, when export readiness is computed, then status is `blocked` and blockers include the new finding id.
- [x] AC-1.3: Given software-instrument regions with readable plugin evidence, when audit runs, then the new blocker is not emitted.

## 4. Technical Design

### 4.3 API Design
No public API shape change. Existing `logic://project/audit` and `logic_project.bounce` preflight surface the new finding through existing `findings` and `export_readiness.blockers`.

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | External MIDI / GM Device regions | Existing `external_midi_regions_bounce_risk` blocker remains authoritative | P0 |
| E2 | Audio tracks with audio regions | New software-instrument audibility blocker does not apply | P1 |
| E3 | Software instrument regions with readable plugin evidence | Export readiness is not blocked by the new guard | P1 |
| E4 | Software instrument regions with stale/unreadable mixer evidence | Block before bounce | P0 |
