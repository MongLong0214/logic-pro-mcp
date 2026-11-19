# Locale campaign runbook (one page)

Goal: re-read Logic's UI labels in ONE language and commit the result. One command does all of it.

## Before you start (30 seconds)
1. You are in the repository worktree and `git status` prints nothing (clean). If not, stop and say so.
2. You are in the tmux window that owns Logic (`tmux -L logic-aqua`, window `gate:0`). Logic needs that
   session's Accessibility permission. If you are not in it, send the command there with
   `tmux -L logic-aqua send-keys -t gate:0 '<command>' Enter`.
3. Nobody else is using Logic. The script checks this itself (the live-run lock); if it says
   `HOLD ... another live run holds Logic`, wait and run it again later. Do nothing else.

## The command
```
Scripts/observations/locale-campaign.sh ko-KR --navigate
```
`--navigate` is part of the command: after the menu-bar and window census it opens each surface the plan
names, reads it and puts it back. Leave it out only when the owner says so.
Replace `ko-KR` with one of `en-US ko-KR ja-JP de-DE es-ES fr-FR it-IT pt-BR zh-CN zh-TW`.
Superseded evidence of the same locale, kind and build is pruned and re-pointed by the script itself.
A variant the apply adds to the Swift is classified by the script itself too (`--reclassify`, then the canon
build and `locale_labels.py --write`, in `docs/canon/README.md`'s order); never classify one by hand.
Add `--no-push` to commit without pushing. It takes about 10 minutes. It switches Logic's language,
relaunches Logic on the test project, reads the screen, updates the label ledger, runs every check,
commits and pushes. It never clicks a dialog.

## Reading the answer
The LAST LINE is the answer. Read only that line.

| last line starts with | meaning | you do |
|---|---|---|
| `RESULT: PASS {` | done, checked, pushed, nothing held | nothing |
| `RESULT: HOLD {` | done, checked, pushed; some readings were held, OR Logic was busy and nothing ran | copy the line to the report; if `reason` says "another live run", run again later |
| `RESULT: FAIL {` | a step failed; nothing after it ran | copy the line; do NOT fix anything by hand; read `failed_step` and `reason` |

`HOLD` is not an error. A held reading is one the script refused to apply because the string on screen is
not exactly the label's own value in Apple's data. They are listed with the reason in
`docs/locale/holds.json`, and nobody applies them by hand.

## If it fails
A FAIL is cleaned up by the script: every tracked file it changed is restored and every untracked file it
wrote is removed (only its own; a file that was dirty before it started is never touched), so the tree ends
clean and the retry passes `clean`. Do not run `git checkout` or `git clean` yourself. The one exception is
a `clean` failure: that is somebody else's uncommitted work, and the script leaves it alone.

| `failed_step` | usual cause | what to do |
|---|---|---|
| `precheck` | a system dialog or a file crawler is running | wait a minute, run again; never click a system dialog |
| `clean` | uncommitted files in the tree | tell the owner; do not commit or discard them |
| `switch` (exit 4) | Logic would not quit (a dialog is open) | tell the owner; do not click it yourself |
| `census` | wrong language came up, or Logic has no window | run again once; if it repeats, report the line |
| `checks` | a repository check failed | report the line and the first failing check; do not edit the ledger |
| `preflight` / `push` | the public-surface preflight or git refused | report the line; the commit is local only |

## Rules that never change
- Every job that drives Logic (`nav-census.py`, `label-census.py run`, `locale-switch.sh` and the campaign)
  takes the live-run lock and refuses while another holds it. Never work around a refusal.
- One locale at a time. Never run two campaigns, and never touch Logic while one runs.
- Never edit `docs/locale/ui-labels.json`, `docs/locale/holds.json` or anything under `docs/observations/`
  by hand. They are written by the tool.
- Never pass `--no-verify` and never skip a hook.
- When all ten are done, put Logic back in Korean: `Scripts/observations/locale-switch.sh ko-KR`.
