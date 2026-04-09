# Clean Machine Validation

## Goal

Validate `Scripts/install.sh` and `Scripts/uninstall.sh` against the published release asset on both supported runner families.

## Automated Matrix

- `macos-15` — Apple Silicon
- `macos-13` — Intel

The release workflow runs both automatically after the signed release job completes.

## What Gets Verified

- Pinned release download
- SHA256 verification
- Team ID metadata lookup
- `codesign` verification
- `spctl` assessment
- install into isolated directory
- key commands preset copy + backup flow in isolated directory
- uninstall cleanup

## Manual Spot Check

On a fresh macOS machine:

```bash
bash Scripts/install.sh
bash Scripts/uninstall.sh
```

Record:

- macOS version
- architecture
- install log
- uninstall log
- Gatekeeper result
- whether Claude registration was skipped or completed
