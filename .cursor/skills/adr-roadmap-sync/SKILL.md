---
name: adr-roadmap-sync
description: Aligns docs/adr/README.md and docs/roadmap/README.md with GitHub issue state for Logic Pro MCP. Use when an ADR index row or roadmap row changes, when an upstream issue opens or closes, or when Scripts/adr-index-matches-github.py or Scripts/roadmap-table-matches-github.py fails.
---

# ADR and roadmap sync

The ADR index and the roadmap are claims about GitHub. A closed issue whose row still says the work is ahead is a failed check, not a style nit.

## Which GitHub repo

`Scripts/adr-index-matches-github.py` always lists issues on `MongLong0214/logic-pro-mcp`.

`Scripts/roadmap-table-matches-github.py` lists issues on the repo `gh` is in, with no `--repo`. On `RolandGasparyan/logic-pro-mcp` that command fails because issues are disabled, and the script exits 2 (`CANNOT DETERMINE`). That exit is not drift. Compare roadmap rows to upstream yourself:

```bash
gh issue list --repo MongLong0214/logic-pro-mcp --state all --limit 500 --json number,state,stateReason,title
```

## Status words

ADR index status is the backticked cell. The parser only sees a full table row.

Unfinished, and illegal on a CLOSED issue: `In Implementation`, `Proposed`, `Draft`, `Accepted`.

Legal on a CLOSED issue: `Shipped`, `Closed`, `Superseded`.

| Upstream close reason | ADR index | Roadmap state cell |
| --- | --- | --- |
| `COMPLETED` | `Shipped` | `closed` |
| `NOT_PLANNED` because the work moved to another issue | `Superseded` | `closed` |
| Still open | leave the unfinished status | `OPEN` |

`Superseded` is not `Shipped`. A not-planned transfer did not implement the feature. Name the issue that now owns the work.

Roadmap state is exactly `OPEN` or `closed`. Other spellings do not parse.

## Edit shape

Change the status cell. Do not rewrite the historical measurement.

On a roadmap row, prepend one sentence, then keep the old cell:

```markdown
| ADR-009 | #292 | closed | Closed 2026-10-08 as completed: the bounded stock-parameter contract. Earlier measurement: …
| ADR-010 | #293 | closed | Closed 2026-09-21 as not planned; remaining implementation is #302. Earlier measurement: …
```

Match the ADR section heading to the new index status, and add one sentence that states why. Leave the rollout notes in place.

Every `docs/adr/ADR-*.md` file needs an index row. A missing row fails the same check as a stale status.

## Verify

From the repo root:

```bash
python3 Scripts/adr-index-matches-github.py
python3 Scripts/test-adr-index-guard.py
python3 Scripts/run-repo-guards.py
```

`adr-index-matches-github.py` must print that the index agrees. Then re-list upstream issues and confirm every roadmap row marked `OPEN` is open and every row just flipped is closed.

Run `python3 Scripts/roadmap-table-matches-github.py` too. Exit 0 means this repo's issues agree. Exit 2 on the fork means issues are disabled here; say that, and rely on the upstream list. Exit 1 is real drift.
