# Live Verification - v3.5.0-pre Source Integration

Date: 2026-06-10 KST
Scope: current source tree on `review/pr17-pr18-strict-live-9663`, covering the Issue #14 stock plugin intelligence surface, Issue #15 workflow skills pack, README media, and live E2E harness hardening.

## Claim Boundary

This is source-tree evidence for the next minor release line. It is not a published stable release claim and it does not change the published `v3.4.6` install surface. The expanded resources must ship as a future `v3.5.0` release before being described as part of the stable artifact.

The live evidence below is from one configured macOS host with Logic Pro 12.2, a visible Logic project, Accessibility permission, Automation permission, CoreMIDI, and the trusted shell/tmux parent used by live client flows. It does not claim coverage for every Logic version, locale, project shape, clean host, or future macOS update.

## Integrated Surface

| Area | Evidence |
|---|---|
| Tools | 8 MCP tools. |
| Static resources | 14 listed resources, including stock plugin and workflow surfaces. |
| Resource templates | 7 templates, including stock plugin and workflow lookup/search. |
| Stock plugin intelligence | 103 documented stock entries with truth-labeled provenance; production output never fabricates `verified` labels. |
| Workflow skills | 7 linted read-only workflow recipes; reading a workflow never executes a mutation. |
| Published-release boundary | README and docs keep `v3.4.6` as published stable and mark this expanded source surface as future `v3.5.0` material. |

## Harness Hardening

The strict live harness no longer counts a missing project state as a passing cycle roundtrip. If `logic://transport/state` cannot expose a document-backed cycle state, default mode records a real skip and strict mode records a failure.

This closes the previous contradiction where a no-project cycle roundtrip path could appear as a green pass while the summary still claimed `0 skipped`.

## Deterministic Gates

| Gate | Result | Evidence |
|---|---:|---|
| Format check | PASS | `git diff --check origin/main...HEAD` exit 0. |
| Formula syntax | PASS | `ruby -c Formula/logic-pro-mcp.rb` -> `Syntax OK`. |
| Python syntax | PASS | `python3 -m py_compile docs/media/render-demo.py Scripts/live-e2e-test.py` exit 0. |
| Full deterministic suite | PASS | `swift test --no-parallel` -> 1256 tests passed, 0 failed. |
| Release build | PASS | `swift build -c release` -> build complete. |
| README media regeneration | PASS | `python3 docs/media/render-demo.py` validated `docs/media/logic-pro-mcp-demo.mp4` and regenerated GIF/thumbnail derivatives. |
| Live capture MP4 | PASS | `ffprobe`: 1920x1080, 24 fps, 144 frames, 6.000000 seconds. |
| README GIF | PASS | `sips`: 920x518. |
| README thumbnail | PASS | `sips`: 1280x720. |

## Strict Live Logic Pro 12.2 Evidence

Command: `LOGIC_PRO_MCP_STRICT_LIVE=1 Scripts/live-e2e-test.sh`

Log directory: `/tmp/logic-pro-mcp-readme-final-1781095615`

| Run | Result | Evidence |
|---|---:|---|
| Run 1 | PASS | `strict-live-run-1.log` -> 307 passed, 0 skipped, 0 failed. |
| Run 2 | PASS | `strict-live-run-2.log` -> 307 passed, 0 skipped, 0 failed. |
| Run 3 | PASS | `strict-live-run-3.log` -> 307 passed, 0 skipped, 0 failed. |
| Total | PASS | 921 passed, 0 skipped, 0 failed. |

Each run reported strict live mode on, Logic Pro running, Accessibility granted, final health permissions granted, final channels started, stock plugin catalog validation, and workflow skills pack validation.

## README Media Evidence

The README hero media is an actual Logic Pro 12.2 screen capture, not a synthetic DAW renderer. `docs/media/render-demo.py` is now only a validator/derivative generator for the captured MP4:

- validates the MP4 spec,
- checks for black frames,
- regenerates `docs/media/logic-pro-mcp-demo.gif`,
- regenerates `docs/media/logic-pro-mcp-thumbnail.png`.

The previous synthetic renderer code path is removed from the script.

## Carried Feature Evidence

| Feature | Evidence |
|---|---|
| Issue #14 stock plugin intelligence | `docs/tickets/issue14-verified-stock-plugin-intelligence/VERIFICATION-2026-06-10.md` |
| Issue #15 workflow skills pack | `docs/tickets/issue15-workflow-skills-pack/VERIFICATION-2026-06-10.md` |
| v3.4.6 stable release | `docs/live-verify-v3.4.6.md` |

## Remaining Non-Claimed Surface

- The source integration is not yet a published stable `v3.5.0` release.
- Multi-version Logic and locale matrix coverage remains future verification work.
- Arbitrary per-parameter plugin value readback remains future work; guarded stock plugin insertion and plugin-slot readback remain the verified write path.
