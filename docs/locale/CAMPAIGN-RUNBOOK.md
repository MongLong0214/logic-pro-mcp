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
Scripts/observations/locale-campaign.sh ko-KR
```
Replace `ko-KR` with one of `en-US ko-KR ja-JP de-DE es-ES fr-FR it-IT pt-BR zh-CN zh-TW`.
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
| `failed_step` | usual cause | what to do |
|---|---|---|
| `precheck` | a system dialog or a file crawler is running | wait a minute, run again; never click a system dialog |
| `clean` | uncommitted files in the tree | tell the owner; do not commit or discard them |
| `switch` (exit 4) | Logic would not quit (a dialog is open) | tell the owner; do not click it yourself |
| `census` | wrong language came up, or Logic has no window | run again once; if it repeats, report the line |
| `checks` | a repository check failed | report the line and the first failing check; do not edit the ledger |
| `preflight` / `push` | the public-surface preflight or git refused | report the line; the commit is local only |

## Rules that never change
- One locale at a time. Never run two campaigns, and never touch Logic while one runs.
- Never edit `docs/locale/ui-labels.json`, `docs/locale/holds.json` or anything under `docs/observations/`
  by hand. They are written by the tool.
- Never pass `--no-verify` and never skip a hook.
- When all ten are done, put Logic back in Korean: `Scripts/observations/locale-switch.sh ko-KR`.
