# Channel EQ AudioUnit Factory Metadata Spike

Date: 2026-07-07

## Scope

This PR adds a public AudioUnit metadata census script for
`PRD-channel-eq-verified-params-vNext` T0. It deliberately does **not** activate
Channel EQ verified params because the script cannot attach to Logic's active
hosted insert.

## Harness

- Script: `Scripts/spike-channel-eq-au-census.swift`
- API: `AudioComponentFindNext`, `AudioComponentInstanceNew`,
  `kAudioUnitProperty_ParameterList`, `kAudioUnitProperty_ParameterInfo`
- Provenance emitted for every parameter: `factory_metadata`
- Activation flag emitted for every parameter: `activation_evidence:false`

## Verified Smoke

Command:

```bash
swift Scripts/spike-channel-eq-au-census.swift
```

Observed:

- Apple `AUNBandEQ` was found.
- Parameter ids/ranges/names were emitted.
- Every record was marked `factory_metadata_only`.
- Summary explicitly stated this cannot activate registry entries by itself.

## Product Decision

Factory metadata may seed candidate ids/ranges for a future live census artifact,
but it is not State A evidence. T3 remains blocked until an active Logic insert
write/read-back surface exists.
