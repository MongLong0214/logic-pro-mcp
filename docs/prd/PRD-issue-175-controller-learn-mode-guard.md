# PRD: Issue 175 Controller Assignments Learn Mode Guard

**Version**: 0.1
**Author**: Product planning
**Date**: 2026-06-23
**Status**: Done
**Size**: S

---

## 1. Problem Statement

### 1.1 Background
Issue #175 reports Logic Pro Controller Assignments Learn Mode intercepting live MIDI/key-command demo operations and opening assignment prompts during recording and playback smoke checks.

### 1.2 Problem Definition
Live demo QA must detect active Controller Assignments Learn Mode or assignment prompts before sending MIDI playback or starting recording. If the state cannot be verified clear, the tooling must fail/skip with a clear diagnostic before driving live MIDI.

### 1.3 Impact of Not Solving
MIDI playback and transport record tests can hang behind Logic prompts, mutate controller assignments, and leave failures attributed to later record/readback checks instead of the real UI precondition.

## 2. Goals & Non-Goals

### 2.1 Goals
- [x] G1: Provide a deterministic helper that classifies Controller Assignments Learn Mode as clear, blocked, or detection error.
- [x] G2: Gate live-e2e MIDI smoke calls and `logic_midi.play_sequence` on a clear Learn Mode guard.
- [x] G3: Gate live-e2e `logic_transport.record` calls on the same guard.
- [x] G4: Surface policy id, reason, and UI evidence when blocked.

### 2.2 Non-Goals
- NG1: Automatically disable Learn Mode or alter Controller Assignments.
- NG2: Change MCP production dispatcher behavior for ordinary clients.
- NG3: Add localization beyond English and Korean markers currently needed by demo QA.

## 3. User Stories & Acceptance Criteria

### US-1: Fail Before Learn Mode Intercepts MIDI
**As a** live demo QA runner, **I want** Learn Mode detected before MIDI playback or transport record, **so that** active controller-learning UI is reported directly instead of blocking the run mid-command.

**Acceptance Criteria:**
- [x] AC-1.1: Given an assignment prompt snapshot, the guard returns blocked with `assignment_prompt_present`.
- [x] AC-1.2: Given a Controller Assignments Learn Mode control with a truthy value, the guard returns blocked with `learn_mode_enabled`.
- [x] AC-1.3: Given no active Learn Mode evidence, the guard returns clear.
- [x] AC-1.4: live-e2e does not call MIDI playback or transport record when the guard is not clear.

## 4. Technical Design

### 4.1 Helper
Add `Scripts/logic_controller_learn_mode.py` with an injectable System Events/JXA runner and pure classifier.

### 4.2 Live E2E Wiring
Run the guard after Logic health readiness is known. Use the result to gate live MIDI smoke calls, `logic_midi.play_sequence`, and `logic_transport.record` sections.

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Assignment prompt already open | Block before live MIDI/record | P0 |
| E2 | Controller Assignments Learn Mode checkbox is active | Block before live MIDI/record | P0 |
| E3 | Detector cannot run | Return error with reason/stderr and do not execute guarded live calls | P1 |
| E4 | Logic is not running | Guard is inactive; existing live readiness gates skip operations | P2 |
