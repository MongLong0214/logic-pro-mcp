### [1/2] MAJOR — the guard accepts a stale count
**Where:** `Foo.swift:120`
Reproduction:
```bash
swift test --filter StaleCountTests
```
### [2/2] MINOR — comment overstates the lock
VERDICT: MERGE
