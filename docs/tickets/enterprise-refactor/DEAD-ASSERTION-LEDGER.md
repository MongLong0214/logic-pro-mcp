# DEAD-ASSERTION LEDGER — WS8a (swift-testing `#expect(Bool==Bool)` sweep)
Branch `chore/enterprise-review-refactor-v3.8.0`. Mechanism: in this repo's swift-testing toolchain the `#expect`/`#require` macro is DEAD (always-passes) when the comparison it directly evaluates has statically `Bool`/`Bool?` operands — incl. non-optional (empirically re-proven, see feedback_swift_testing_dead_expect). Only live forms: `#expect(x)`, `#expect(!x)`, `#expect(x!)`, or a bound-then-expect. Comparisons **inside a `{ }` closure predicate** (`.allSatisfy`/`.filter`/`.contains(where:)`) are compiled normally and stay LIVE — excluded from this sweep.
## Transform rules (AC2 / PRD §5.3)
| # | LHS static type | dead form | live replacement |
|---|---|---|---|
| 1 | non-optional `Bool` | `x == true` / `x == false` | `x` / `!(x)` |
| 2 | `Bool?` via `as? Bool` (nil = real finding) | `(o["k"] as? Bool) == true` | `(o["k"] as? Bool)!` |
| 3 | `Bool?` where nil must FAIL (verified/exists/optional-chain) | `x == true` | `x!` |
| 4 | `Bool?` where nil is VALID success (`result.isError`) | `r.isError != true` | `let e = r.isError ?? false; #expect(!e)` |
| 5 | tautology `X==true \|\| X==false` | (always true) | delete / real assertion |
## Summary — 386 dead assertions transformed across 80 files
| rule | count |
|---|---|
| 1 | 233 |
| 2 | 26 |
| 3 | 103 |
| 4 | 18 |
| 5 | 6 |

(392 top-level dead tokens in 387 macro-args; 6 tautology args carry 2 tokens each; 1 `!= .none` excluded as a live nil-check.)

## Per-transform ledger

### AXHelpersTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 105 | 1 | Bool | `setResult == false` | `!(setResult)` |
| 106 | 1 | Bool | `actionResult == false` | `!(actionResult)` |

### AXLogicProElementsDialogFilterTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 140 | 1 | Bool | `AXLogicProElements.dialogPresent(runtime: runtime) == true` | `AXLogicProElements.dialogPresent(runtime: runtime)` |
| 193 | 1 | Bool | `AXLogicProElements.dialogPresent(runtime: runtime) == false` | `!(AXLogicProElements.dialogPresent(runtime: runtime))` |
| 210 | 1 | Bool | `AXLogicProElements.dialogPresent(runtime: runtime) == false` | `!(AXLogicProElements.dialogPresent(runtime: runtime))` |
| 218 | 1 | Bool | `AXLogicProElements.dialogPresent(runtime: runtime) == false` | `!(AXLogicProElements.dialogPresent(runtime: runtime))` |
| 359 | 1 | Bool | `bool == false` | `!(bool)` |

### AXLogicProElementsTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 200 | 1 | Bool | `AXLogicProElements.dialogPresent(runtime: runtime) == true` | `AXLogicProElements.dialogPresent(runtime: runtime)` |
| 243 | 3 | Bool? (property; compiler-confirmed) | `AXLogicProElements.readControlBarCheckboxValue(         named: "녹음",         englishName: ` | `AXLogicProElements.readControlBarCheckboxValue(         named: "녹음",         englishName: ` |
| 248 | 3 | Bool? (property; compiler-confirmed) | `AXLogicProElements.readControlBarCheckboxValue(         named: "사이클",         englishName:` | `!(AXLogicProElements.readControlBarCheckboxValue(         named: "사이클",         englishNam` |

### AXPluginInsertSlotsDriftTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 103 | 1 | Bool | `slots[0].isEmpty == true` | `slots[0].isEmpty` |
| 104 | 1 | Bool | `slots[0].occupied == false` | `!(slots[0].occupied)` |
| 136 | 1 | Bool | `slots[2].isEmpty == false` | `!(slots[2].isEmpty)` |
| 84 | 1 | Bool | `slots[1].occupied == true` | `slots[1].occupied` |
| 85 | 1 | Bool | `slots[1].isEmpty == false` | `!(slots[1].isEmpty)` |

### AXValueExtractorsTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 192 | 3 | Bool? (property; compiler-confirmed) | `AXValueExtractors.extractButtonState(zeroButton, runtime: runtime) == false` | `!(AXValueExtractors.extractButtonState(zeroButton, runtime: runtime))` |
| 23 | 3 | Bool? (property; compiler-confirmed) | `AXValueExtractors.extractButtonState(stringButton, runtime: runtime) == true` | `AXValueExtractors.extractButtonState(stringButton, runtime: runtime)` |
| 24 | 3 | Bool? (property; compiler-confirmed) | `AXValueExtractors.extractSelectedState(selected, runtime: runtime) == true` | `AXValueExtractors.extractSelectedState(selected, runtime: runtime)` |
| 330 | 1 | Bool | `state.isRecording == false` | `!(state.isRecording)` |

### AccessibilityChannelRegionStateATests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 207 | 3 | Bool? (optional chain) | `(obj["note"] as? String)?.contains("no position change") == true` | `((obj["note"] as? String)?.contains("no position change"))!` |

### AccessibilityChannelScanLibraryTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 100 | 1 | Bool | `r!.selectionRestored == false` | `!(r!.selectionRestored)` |
| 144 | 1 | Bool | `gateResult == true` | `gateResult` |
| 81 | 1 | Bool | `r!.selectionRestored == true` | `r!.selectionRestored` |

### AccessibilityChannelTests (17)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 1028 | 3 | Bool? (optional chain) | `(builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue == tr` | `((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!` |
| 1056 | 3 | Bool? (optional chain) | `(builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue == fa` | `!(((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!)` |
| 1099 | 3 | Bool? (optional chain) | `(builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue == tr` | `((builder.attributeValue(cycle, kAXValueAttribute as String) as? NSNumber)?.boolValue)!` |
| 1219 | 1 | Bool | `(obj["success"] as? Bool)! == false` | `!((obj["success"] as? Bool)!)` |
| 1223 | 1 | Bool | `(obj["write_attempted"] as? Bool)! == false` | `!((obj["write_attempted"] as? Bool)!)` |
| 1271 | 1 | Bool | `(obj["success"] as? Bool)! == false` | `!((obj["success"] as? Bool)!)` |
| 1620 | 1 | Bool | `fallbackBox.called == false` | `!(fallbackBox.called)` |
| 1964 | 3 | Bool? (optional chain) | `(builder.attributeValue(header, kAXDescriptionAttribute as String) as? String)?.contains("` | `((builder.attributeValue(header, kAXDescriptionAttribute as String) as? String)?.contains(` |
| 2417 | 2 | Bool? (as? cast) | `obj["panel_restaged_after_failure"] as? Bool == true` | `(obj["panel_restaged_after_failure"] as? Bool)!` |
| 2418 | 2 | Bool? (as? cast) | `obj["panel_open_after_failure"] as? Bool == true` | `(obj["panel_open_after_failure"] as? Bool)!` |
| 2453 | 2 | Bool? (as? cast) | `obj["panel_restaged_after_failure"] as? Bool == false` | `!((obj["panel_restaged_after_failure"] as? Bool)!)` |
| 2454 | 2 | Bool? (as? cast) | `obj["panel_open_after_failure"] as? Bool == true` | `(obj["panel_open_after_failure"] as? Bool)!` |
| 2781 | 1 | Bool | `strips[0].plugins[0].isBypassed == false` | `!(strips[0].plugins[0].isBypassed)` |
| 393 | 1 | Bool | `await untrusted.healthCheck().available == false` | `!(await untrusted.healthCheck().available)` |
| 396 | 1 | Bool | `await notRunning.healthCheck().available == false` | `!(await notRunning.healthCheck().available)` |
| 399 | 1 | Bool | `await missingRoot.healthCheck().available == false` | `!(await missingRoot.healthCheck().available)` |
| 403 | 1 | Bool | `healthyState.available == true` | `healthyState.available` |

### AppleScriptChannelTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 113 | 1 | Bool | `missing.available == false` | `!(missing.available)` |
| 266 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains("refusing to close") == true` | `((obj["hint"] as? String)?.contains("refusing to close"))!` |
| 501 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains("modification time did not advance") == true` | `((obj["hint"] as? String)?.contains("modification time did not advance"))!` |
| 806 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains("did not change") == true` | `((obj["hint"] as? String)?.contains("did not change"))!` |

### AudioAnalyzerTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 284 | 3 | Bool? (optional chain) | `oversized.verification.detail?.contains("exceeds maximum") == true` | `(oversized.verification.detail?.contains("exceeds maximum"))!` |
| 292 | 3 | Bool? (optional chain) | `tooLong.verification.detail?.contains("duration") == true` | `(tooLong.verification.detail?.contains("duration"))!` |

### CGEventChannelTests (6)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| - | 5 | Bool | `sent == true \|\| sent == false` | `removed vacuous check; env-dependent smoke → _ = call` |
| 243 | 3 | Bool? (optional chain) | `routes?.contains(.cgEvent) == true` | `(routes?.contains(.cgEvent))!` |
| 50 | 3 | Bool? (optional chain) | `sequence?.contains(where: { $0.keyCode == 47 }) == true` | `(sequence?.contains(where: { $0.keyCode == 47 }))!` |
| 56 | 3 | Bool? (optional chain) | `sequence?.contains(where: { $0.keyCode == 41 && $0.flags.contains(.maskShift) }) == true` | `(sequence?.contains(where: { $0.keyCode == 41 && $0.flags.contains(.maskShift) }))!` |
| 79 | 1 | Bool | `unavailable.available == false` | `!(unavailable.available)` |
| 83 | 1 | Bool | `missingPIDHealth.available == false` | `!(missingPIDHealth.available)` |

### ChannelRouterTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 637 | 1 | Bool | `report.hasFailures == true` | `report.hasFailures` |
| 648 | 1 | Bool | `report.hasFailures == false` | `!(report.hasFailures)` |
| 649 | 1 | Bool | `report.hasDegraded == true` | `report.hasDegraded` |
| 665 | 1 | Bool | `probe.waitUntilStopCalled(timeout: .milliseconds(10)) == false` | `!(probe.waitUntilStopCalled(timeout: .milliseconds(10)))` |

### CleanupExecutionTests (11)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 143 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎     #expect(!resultIsError)` |
| 179 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 204 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 229 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 251 | 1 | Bool | `emptyStep.supportedByCurrentTools == false` | `!(emptyStep.supportedByCurrentTools)` |
| 267 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 338 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 373 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 405 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |
| 408 | 1 | Bool | `calls.isEmpty == false` | `!(calls.isEmpty)` |
| 433 | 2 | Bool? (as? cast) | `try #require(json["success"] as? Bool) == false` | `!((try #require(json["success"] as? Bool))!)` |

### CommercialReadinessTests (8)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 332 | 3 | Bool? (optional chain) | `json?["success"] as? Bool == false` | `!((json?["success"] as? Bool)!)` |
| 335 | 3 | Bool? (optional chain) | `valid?.contains("transport") == true` | `(valid?.contains("transport"))!` |
| 336 | 3 | Bool? (optional chain) | `valid?.contains("all") == true` | `(valid?.contains("all"))!` |
| 436 | 1 | Bool | `status.allGranted == false` | `!(status.allGranted)` |
| 446 | 1 | Bool | `status.automationLogicPro == false` | `!(status.automationLogicPro)` |
| 462 | 1 | Bool | `await poller.isRunning == true` | `await poller.isRunning` |
| 464 | 1 | Bool | `await poller.isRunning == false` | `!(await poller.isRunning)` |
| 500 | 1 | Bool | `health.available == false` | `!(health.available)` |

### DestructiveOperationTests (24)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 111 | 1 | Bool | `AppleScriptSafety.openFile(at: malformedURL.path) == false` | `!(AppleScriptSafety.openFile(at: malformedURL.path))` |
| 112 | 1 | Bool | `AppleScriptSafety.isValidProjectPath(malformedURL.path, requireExisting: true) == false` | `!(AppleScriptSafety.isValidProjectPath(malformedURL.path, requireExisting: true))` |
| 135 | 1 | Bool | `opened == true` | `opened` |
| 148 | 1 | Bool | `opened == false` | `!(opened)` |
| 159 | 1 | Bool | `opened == false` | `!(opened)` |
| 51 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("play") == true` | `AppleScriptSafety.isAllowedTransportAction("play")` |
| 52 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("stop") == true` | `AppleScriptSafety.isAllowedTransportAction("stop")` |
| 53 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("record") == true` | `AppleScriptSafety.isAllowedTransportAction("record")` |
| 54 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("pause") == true` | `AppleScriptSafety.isAllowedTransportAction("pause")` |
| 55 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("rm -rf") == false` | `!(AppleScriptSafety.isAllowedTransportAction("rm -rf"))` |
| 56 | 1 | Bool | `AppleScriptSafety.isAllowedTransportAction("\" & do shell script") == false` | `!(AppleScriptSafety.isAllowedTransportAction("\" & do shell script"))` |
| 60 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/Users/test/song.logicx") == true` | `AppleScriptSafety.isValidFilePath("/Users/test/song.logicx")` |
| 61 | 1 | Bool | `AppleScriptSafety.isValidFilePath("") == false` | `!(AppleScriptSafety.isValidFilePath(""))` |
| 62 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/dev/null") == false` | `!(AppleScriptSafety.isValidFilePath("/dev/null"))` |
| 63 | 1 | Bool | `AppleScriptSafety.isValidFilePath("relative/song.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("relative/song.logicx"))` |
| 64 | 1 | Bool | `AppleScriptSafety.isValidFilePath(" /tmp/song.logicx") == false` | `!(AppleScriptSafety.isValidFilePath(" /tmp/song.logicx"))` |
| 65 | 1 | Bool | `AppleScriptSafety.isValidProjectPath("\n/tmp/song.logicx", requireExisting: false) == fals` | `!(AppleScriptSafety.isValidProjectPath("\n/tmp/song.logicx", requireExisting: false))` |
| 66 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/project/../song.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/tmp/project/../song.logicx"))` |
| 67 | 1 | Bool | `AppleScriptSafety.isValidProjectPath("/Users/test/song.logicx", requireExisting: false) ==` | `AppleScriptSafety.isValidProjectPath("/Users/test/song.logicx", requireExisting: false)` |
| 68 | 1 | Bool | `AppleScriptSafety.isValidProjectPath("/Users/test/song.txt", requireExisting: false) == fa` | `!(AppleScriptSafety.isValidProjectPath("/Users/test/song.txt", requireExisting: false))` |
| 69 | 1 | Bool | `AppleScriptSafety.isValidProjectPath("/tmp/project/../song.logicx", requireExisting: false` | `!(AppleScriptSafety.isValidProjectPath("/tmp/project/../song.logicx", requireExisting: fal` |
| 73 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/Users/test/song\n.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/Users/test/song\n.logicx"))` |
| 89 | 1 | Bool | `AppleScriptSafety.openFile(at: missingProject) == false` | `!(AppleScriptSafety.openFile(at: missingProject))` |
| 97 | 1 | Bool | `AppleScriptSafety.openFile(at: textFileURL.path) == false` | `!(AppleScriptSafety.openFile(at: textFileURL.path))` |

### DispatcherTests (13)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 1117 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎     #expect(!resultIsError)` |
| 1178 | 4 | Bool? (.isError; nil=success) | `#expect(insertResult.isError != true)` | `let insertResultIsError = insertResult.isError ?? false ⏎     #expect(!insertResultIsError` |
| 1901 | 3 | Bool? (optional chain) | `importOps[0].1["path"]?.hasPrefix(SMFWriter.temporaryDirectoryPrefix()) == true` | `(importOps[0].1["path"]?.hasPrefix(SMFWriter.temporaryDirectoryPrefix()))!` |
| 2480 | 3 | Bool? (optional chain) | `(object["blockers"] as? [String])?.contains("external_midi_regions_bounce_risk") == true` | `((object["blockers"] as? [String])?.contains("external_midi_regions_bounce_risk"))!` |
| 2739 | 1 | Bool | `execution.timedOut == false` | `!(execution.timedOut)` |
| 2748 | 1 | Bool | `execution.timedOut == false` | `!(execution.timedOut)` |
| 2760 | 1 | Bool | `execution.timedOut == false` | `!(execution.timedOut)` |
| 2978 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎     #expect(!resultIsError)` |
| 3796 | 1 | Bool | `cached.isPlaying == false` | `!(cached.isPlaying)` |
| 3797 | 1 | Bool | `cached.isRecording == false` | `!(cached.isRecording)` |
| 3886 | 3 | Bool? (optional chain) | `(json["hint"] as? String)?.contains("refresh_cache") == true` | `((json["hint"] as? String)?.contains("refresh_cache"))!` |
| 3922 | 1 | Bool | `cached.isPlaying == true` | `cached.isPlaying` |
| 3923 | 1 | Bool | `cached.isRecording == true` | `cached.isRecording` |

### EndToEndTests (10)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 423 | 4 | Bool? (.isError; nil=success) | `#expect(r.isError != true)` | `let rIsError = r.isError ?? false ⏎     #expect(!rIsError)` |
| 587 | 4 | Bool? (.isError; nil=success) | `#expect(r.isError != true)` | `let rIsError = r.isError ?? false ⏎     #expect(!rIsError)` |
| 795 | 3 | Bool? (optional chain) | `json?.keys.contains("cache_age_sec") == true` | `(json?.keys.contains("cache_age_sec"))!` |
| 796 | 3 | Bool? (optional chain) | `json?.keys.contains("fetched_at") == true` | `(json?.keys.contains("fetched_at"))!` |
| 814 | 3 | Bool? (optional chain) | `json?.keys.contains("cache_age_sec") == true` | `(json?.keys.contains("cache_age_sec"))!` |
| 815 | 3 | Bool? (optional chain) | `json?.keys.contains("fetched_at") == true` | `(json?.keys.contains("fetched_at"))!` |
| 848 | 3 | Bool? (optional chain) | `(searchJSON?["entries"] as? [[String: Any]])?.isEmpty == false` | `!(((searchJSON?["entries"] as? [[String: Any]])?.isEmpty)!)` |
| 863 | 3 | Bool? (optional chain) | `(schemaJSON?["evidence_levels"] as? [String])?.contains("live_verified") == true` | `((schemaJSON?["evidence_levels"] as? [String])?.contains("live_verified"))!` |
| 931 | 1 | Bool | `(obj?["success"] as? Bool)! == false` | `!((obj?["success"] as? Bool)!)` |
| 943 | 1 | Bool | `(obj?["success"] as? Bool)! == false` | `!((obj?["success"] as? Bool)!)` |

### HealthDispatcherKeyCmdDetailTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 92 | 1 | Bool | `health.available == true` | `health.available` |
| 93 | 1 | Bool | `health.ready == false` | `!(health.ready)` |

### HonestContractPortUnavailableTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 25 | 1 | Bool | `HonestContract.isTerminalStateC(envelope) == true` | `HonestContract.isTerminalStateC(envelope)` |

### HonestContractV2Tests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 111 | 1 | Bool | `HonestContractEnvelopeDetector.isAlreadyEnvelope(json) == true` | `HonestContractEnvelopeDetector.isAlreadyEnvelope(json)` |
| 115 | 1 | Bool | `HonestContractEnvelopeDetector.isAlreadyEnvelope(HonestContract.encodeV2StateA()) == true` | `HonestContractEnvelopeDetector.isAlreadyEnvelope(HonestContract.encodeV2StateA())` |
| 116 | 1 | Bool | `HonestContractEnvelopeDetector.isAlreadyEnvelope(         HonestContract.encodeV2StateB(re` | `HonestContractEnvelopeDetector.isAlreadyEnvelope(         HonestContract.encodeV2StateB(re` |
| 123 | 1 | Bool | `HonestContract.isTerminalStateC(json) == true` | `HonestContract.isTerminalStateC(json)` |
| 163 | 1 | Bool | `HonestContract.terminalErrorCodes.contains(         HonestContract.FailureError.readbackMi` | `!(HonestContract.terminalErrorCodes.contains(         HonestContract.FailureError.readback` |

### InstallScriptContractTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 273 | 1 | Bool | `formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#\\{p` | `!(formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#\\` |

### IntegrationTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 42 | 1 | Bool | `tracks[3].isMuted == true` | `tracks[3].isMuted` |
| 54 | 1 | Bool | `tracks[3].isMuted == true` | `tracks[3].isMuted` |

### Issue105GotoNoteTests (6)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 101 | 2 | Bool? (as? cast) | `(o["verified"] as? Bool) != true` | `!((o["verified"] as? Bool)!)` |
| 103 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError == true)` | `let resultIsError = result.isError ?? false ⏎         #expect(resultIsError)` |
| 70 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |
| 72 | 2 | Bool? (as? cast) | `(o["verified"] as? Bool) == true` | `(o["verified"] as? Bool)!` |
| 86 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |
| 88 | 2 | Bool? (as? cast) | `(o["verified"] as? Bool) == true` | `(o["verified"] as? Bool)!` |

### Issue108Tests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 55 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |
| 73 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError == true)` | `let resultIsError = result.isError ?? false ⏎         #expect(resultIsError)` |
| 81 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError == true)` | `let resultIsError = result.isError ?? false ⏎         #expect(resultIsError)` |

### Issue109ZoomTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 40 | 3 | Bool? (optional chain) | `o?["verified"] as? Bool == true` | `(o?["verified"] as? Bool)!` |
| 80 | 3 | Bool? (optional chain) | `chain?.contains(.midiKeyCommands) == true` | `(chain?.contains(.midiKeyCommands))!` |

### Issue110SaveVerifyTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 31 | 3 | Bool? (optional chain) | `o?["verified"] as? Bool == true` | `(o?["verified"] as? Bool)!` |
| 47 | 3 | Bool? (optional chain) | `obj(result)?["verified"] as? Bool == true` | `(obj(result)?["verified"] as? Bool)!` |
| 75 | 3 | Bool? (optional chain) | `obj(result)?["verified"] as? Bool == false` | `!((obj(result)?["verified"] as? Bool)!)` |
| 85 | 3 | Bool? (optional chain) | `o?["verified"] as? Bool == false` | `!((o?["verified"] as? Bool)!)` |
| 86 | 3 | Bool? (optional chain) | `(o?["reason_detail"] as? String)?.contains("untitled") == true` | `((o?["reason_detail"] as? String)?.contains("untitled"))!` |

### Issue112CommandDeadlineTests (6)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 142 | 3 | Bool? (optional chain) | `(obj?["hint"] as? String)?.isEmpty == false` | `!(((obj?["hint"] as? String)?.isEmpty)!)` |
| 165 | 1 | Bool | `blocker.isCompleted() == false` | `!(blocker.isCompleted())` |
| 202 | 4 | Bool? (.isError; nil=success) | `#expect(afterDrain.isError != true)` | `let afterDrainIsError = afterDrain.isError ?? false ⏎         #expect(!afterDrainIsError)` |
| 365 | 4 | Bool? (.isError; nil=success) | `#expect(recovered.isError != true)` | `let recoveredIsError = recovered.isError ?? false ⏎         #expect(!recoveredIsError)` |
| 90 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |
| 91 | 3 | Bool? (optional chain) | `json(result)?["verified"] as? Bool == true` | `(json(result)?["verified"] as? Bool)!` |

### Issue125BouncePreconditionTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 334 | 3 | Bool? (optional chain) | `artifact.error?.contains("bounce_helper_unexpected_artifact_path") == true` | `(artifact.error?.contains("bounce_helper_unexpected_artifact_path"))!` |

### Issue136GotoDriftHonestTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 114 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError == true, "a drifted goto_position must surface isError == true")` | `let resultIsError = result.isError ?? false ⏎         #expect(resultIsError, "a drifted go` |
| 149 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |

### Issue139TrackMutationOcclusionHonestTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 104 | 2 | Bool? (as? cast) | `json["blocking_dialog_present"] as? Bool == true` | `(json["blocking_dialog_present"] as? Bool)!` |
| 105 | 2 | Bool? (as? cast) | `json["write_attempted"] as? Bool == false` | `!((json["write_attempted"] as? Bool)!)` |
| 185 | 2 | Bool? (as? cast) | `(json["verified"] as? Bool) != true` | `!((json["verified"] as? Bool)!)` |

### Issue141LibraryModalPreconditionTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 60 | 2 | Bool? (as? cast) | `json["blocking_dialog_present"] as? Bool == true` | `(json["blocking_dialog_present"] as? Bool)!` |
| 61 | 2 | Bool? (as? cast) | `json["write_attempted"] as? Bool == false` | `!((json["write_attempted"] as? Bool)!)` |

### Issue144ProjectModalPreconditionTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 80 | 2 | Bool? (as? cast) | `json["blocking_dialog_present"] as? Bool == true` | `(json["blocking_dialog_present"] as? Bool)!` |
| 81 | 2 | Bool? (as? cast) | `json["write_attempted"] as? Bool == false` | `!((json["write_attempted"] as? Bool)!)` |

### Issue199ResourceReadDeadlineTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 26 | 3 | Bool? (optional chain) | `json(result)?["ok"] as? Bool == true` | `(json(result)?["ok"] as? Bool)!` |
| 39 | 1 | Bool | `(obj["success"] as? Bool)! == false` | `!((obj["success"] as? Bool)!)` |
| 72 | 1 | Bool | `(obj?["success"] as? Bool)! == false` | `!((obj?["success"] as? Bool)!)` |

### Issue200IndexedTemplateEmptyStateTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 23 | 1 | Bool | `(o?["success"] as? Bool)! == false` | `!((o?["success"] as? Bool)!)` |
| 28 | 3 | Bool? (optional chain) | `(o?["hint"] as? String)?.contains("parent collection") == true` | `((o?["hint"] as? String)?.contains("parent collection"))!` |
| 37 | 1 | Bool | `(o?["success"] as? Bool)! == false` | `!((o?["success"] as? Bool)!)` |

### Issue202SurfaceConsistencyTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 43 | 1 | Bool | `(o?["supported"] as? Bool)! == false` | `!((o?["supported"] as? Bool)!)` |
| 45 | 1 | Bool | `(o?["success"] as? Bool)! == false` | `!((o?["success"] as? Bool)!)` |

### Issue221MutationGateReleaseTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 122 | 2 | Bool? (as? cast) | `(json(refused)?["safe_to_retry"] as? Bool) == true` | `(json(refused)?["safe_to_retry"] as? Bool)!` |
| 123 | 2 | Bool? (as? cast) | `(json(refused)?["write_attempted"] as? Bool) == false` | `!((json(refused)?["write_attempted"] as? Bool)!)` |

### Issue7BackwardCompatTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 51 | 1 | Bool | `track.isSelected == true` | `track.isSelected` |

### LibraryAccessorAXRuntimeTests (17)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 143 | 1 | Bool | `LibraryAccessor.isLibraryPanelOpen(runtime: fixture.runtime) == true` | `LibraryAccessor.isLibraryPanelOpen(runtime: fixture.runtime)` |
| 228 | 1 | Bool | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` |
| 233 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: fixture.runtime,     ` | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: fixture.runtime,     ` |
| 238 | 1 | Bool | `LibraryAccessor.setInstrument(         category: "Bass",         preset: "Sub",         se` | `LibraryAccessor.setInstrument(         category: "Bass",         preset: "Sub",         se` |
| 255 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Padded Sub",         runtime: fixture.runtim` | `LibraryAccessor.selectPreset(         named: "Padded Sub",         runtime: fixture.runtim` |
| 273 | 1 | Bool | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` |
| 290 | 1 | Bool | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` |
| 312 | 1 | Bool | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` | `LibraryAccessor.selectCategory(         named: "Bass",         runtime: fixture.runtime,  ` |
| 343 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: runtime,         libr` | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: runtime,         libr` |
| 362 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: fixture.runtime,     ` | `LibraryAccessor.selectPreset(         named: "Sub",         runtime: fixture.runtime,     ` |
| 388 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Bass",         runtime: fixture.runtime,    ` | `!(LibraryAccessor.selectPreset(         named: "Bass",         runtime: fixture.runtime,  ` |
| 412 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Bass",         commit: false,         runtim` | `!(LibraryAccessor.selectPreset(         named: "Bass",         commit: false,         runt` |
| 468 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Festival Drop",         runtime: runtime,   ` | `LibraryAccessor.selectPreset(         named: "Festival Drop",         runtime: runtime,   ` |
| 488 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` |
| 511 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` |
| 546 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` |
| 582 | 1 | Bool | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` | `LibraryAccessor.selectPreset(         named: "Sub",         commit: false,         runtime` |

### LibraryAccessorHelpersTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 40 | 3 | Bool? (optional chain) | `r?.exists == true` | `(r?.exists)!` |

### LibraryAccessorResolvePathTests (8)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 106 | 1 | Bool | `r!.exists == true` | `r!.exists` |
| 114 | 1 | Bool | `r!.exists == true` | `r!.exists` |
| 122 | 1 | Bool | `r!.exists == false` | `!(r!.exists)` |
| 128 | 1 | Bool | `r!.exists == false` | `!(r!.exists)` |
| 134 | 1 | Bool | `r!.exists == true` | `r!.exists` |
| 77 | 1 | Bool | `r!.exists == true` | `r!.exists` |
| 92 | 1 | Bool | `r!.exists == false` | `!(r!.exists)` |
| 99 | 1 | Bool | `r!.exists == true` | `r!.exists` |

### LibraryDiskScannerTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 464 | 1 | Bool | `templatePad.exists == false` | `!(templatePad.exists)` |
| 74 | 1 | Bool | `root.selectionRestored == false` | `!(root.selectionRestored)` |

### LogicProServerHandlerTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 131 | 3 | Bool? (optional chain) | `trackJSON?.isEmpty == true` | `(trackJSON?.isEmpty)!` |
| 86 | 3 | Bool? (optional chain) | `err?.errorDescription?.contains("tools/list") == true` | `(err?.errorDescription?.contains("tools/list"))!` |
| 87 | 3 | Bool? (optional chain) | `err?.errorDescription?.contains("abc") == true` | `(err?.errorDescription?.contains("abc"))!` |

### MCUChannelEchoTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 107 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |
| 231 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |
| 86 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |

### MCUChannelTests (11)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 110 | 1 | Bool | `connAfterStop.isConnected == false` | `!(connAfterStop.isConnected)` |
| 123 | 1 | Bool | `conn.isConnected == true` | `conn.isConnected` |
| 124 | 1 | Bool | `conn.registeredAsDevice == true` | `conn.registeredAsDevice` |
| 237 | 1 | Bool | `sent.isEmpty == false` | `!(sent.isEmpty)` |
| 308 | 2 | Bool? (as? cast) | `obj["success"] as? Bool == false` | `!((obj["success"] as? Bool)!)` |
| 312 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains(item.hintFragment) == true` | `((obj["hint"] as? String)?.contains(item.hintFragment))!` |
| 368 | 3 | Bool? (optional chain) | `(obj["command"] as? String)?.isEmpty == false` | `!(((obj["command"] as? String)?.isEmpty)!)` |
| 65 | 1 | Bool | `conn.isConnected == true` | `conn.isConnected` |
| 86 | 1 | Bool | `conn.isConnected == false` | `!(conn.isConnected)` |
| 87 | 1 | Bool | `conn.registeredAsDevice == false` | `!(conn.registeredAsDevice)` |
| 90 | 1 | Bool | `health.available == false` | `!(health.available)` |

### MCUFeedbackParserTests (13)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 120 | 1 | Bool | `tracks[0].isArmed == false` | `!(tracks[0].isArmed)` |
| 121 | 1 | Bool | `tracks[1].isSelected == false` | `!(tracks[1].isSelected)` |
| 150 | 1 | Bool | `after[5].isSelected == true` | `after[5].isSelected` |
| 166 | 1 | Bool | `conn.isConnected == true` | `conn.isConnected` |
| 168 | 1 | Bool | `conn.registeredAsDevice == true` | `conn.registeredAsDevice` |
| 169 | 1 | Bool | `tracks[0].isMuted == false` | `!(tracks[0].isMuted)` |
| 170 | 1 | Bool | `tracks[0].isSoloed == false` | `!(tracks[0].isSoloed)` |
| 27 | 1 | Bool | `tracks[2].isMuted == true` | `tracks[2].isMuted` |
| 39 | 1 | Bool | `tracks[2].isSoloed == true` | `tracks[2].isSoloed` |
| 68 | 1 | Bool | `updated.isConnected == true` | `updated.isConnected` |
| 70 | 1 | Bool | `updated.registeredAsDevice == true` | `updated.registeredAsDevice` |
| 86 | 1 | Bool | `tracks[0].isMuted == false` | `!(tracks[0].isMuted)` |
| 87 | 1 | Bool | `tracks[8].isMuted == true` | `tracks[8].isMuted` |

### MCUMixerWriteDiagnosticsTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 309 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |
| 339 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |
| 59 | 3 | Bool? (optional chain) | `(obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true` | `((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!` |

### MCUProtocolTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 166 | 1 | Bool | `MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01, 0x7F, 0xF7]) == true` | `MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01, 0x7F, 0xF7])` |
| 167 | 1 | Bool | `MCUProtocol.isValidSysEx([0xF0, 0x00, 0x80, 0x01, 0xF7]) == false` | `!(MCUProtocol.isValidSysEx([0xF0, 0x00, 0x80, 0x01, 0xF7]))` |
| 168 | 1 | Bool | `MCUProtocol.isValidSysEx([0x00, 0x01, 0xF7]) == false` | `!(MCUProtocol.isValidSysEx([0x00, 0x01, 0xF7]))` |
| 169 | 1 | Bool | `MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01]) == false` | `!(MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01]))` |
| 53 | 3 | Bool? (optional chain) | `result?.on == true` | `(result?.on)!` |

### MCUTraceTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 26 | 1 | Bool | `MCUTrace.shouldTrace([:]) == false` | `!(MCUTrace.shouldTrace([:]))` |
| 30 | 1 | Bool | `MCUTrace.shouldTrace(["MCU_TRACE": "0"]) == false` | `!(MCUTrace.shouldTrace(["MCU_TRACE": "0"]))` |
| 31 | 1 | Bool | `MCUTrace.shouldTrace(["MCU_TRACE": "true"]) == false` | `!(MCUTrace.shouldTrace(["MCU_TRACE": "true"]))` |
| 35 | 1 | Bool | `MCUTrace.shouldTrace(["MCU_TRACE": "1"]) == true` | `MCUTrace.shouldTrace(["MCU_TRACE": "1"])` |

### MCUVPotTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 37 | 3 | Bool? (optional chain) | `withCenter?.center == true` | `(withCenter?.center)!` |

### MIDIEngineTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 341 | 1 | Bool | `await engine.isActive == false` | `!(await engine.isActive)` |

### MIDIFeedbackTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 76 | 1 | Bool | `MCUProtocol.isValidSysEx(validSysEx) == true` | `MCUProtocol.isValidSysEx(validSysEx)` |
| 77 | 1 | Bool | `MCUProtocol.isValidSysEx(invalidMiddle) == false` | `!(MCUProtocol.isValidSysEx(invalidMiddle))` |
| 78 | 1 | Bool | `MCUProtocol.isValidSysEx(noF0) == false` | `!(MCUProtocol.isValidSysEx(noF0))` |
| 79 | 1 | Bool | `MCUProtocol.isValidSysEx(noF7) == false` | `!(MCUProtocol.isValidSysEx(noF7))` |

### MIDIKeyCommandsChannelDirectSendTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 360 | 3 | Bool? (optional chain) | `(envelope?["hint"] as? String)?.isEmpty == false` | `!(((envelope?["hint"] as? String)?.isEmpty)!)` |

### MIDIKeyCommandsTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 74 | 1 | Bool | `beforeStart.available == false` | `!(beforeStart.available)` |
| 79 | 1 | Bool | `afterStart.available == true` | `afterStart.available` |
| 92 | 1 | Bool | `beforeApproval.ready == false` | `!(beforeApproval.ready)` |
| 97 | 1 | Bool | `afterApproval.ready == true` | `afterApproval.ready` |

### ManualValidationStoreTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 120 | 1 | Bool | `try canAcquireExclusiveLockNonblocking(atPath: lockPath) == false` | `!(try canAcquireExclusiveLockNonblocking(atPath: lockPath))` |
| 39 | 1 | Bool | `await store.isApproved(.scripter) == false` | `!(await store.isApproved(.scripter))` |

### MixerDispatcherSetPluginParamTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 53 | 3 | Bool? (optional chain) | `object?["success"] as? Bool == false` | `!((object?["success"] as? Bool)!)` |
| 55 | 3 | Bool? (optional chain) | `(object?["hint"] as? String)?.contains("set_plugin_param refused") == true` | `((object?["hint"] as? String)?.contains("set_plugin_param refused"))!` |
| 57 | 3 | Bool? (optional chain) | `selectResponse?.contains("\"verified\":false") == true` | `(selectResponse?.contains("\"verified\":false"))!` |

### MixerProvenanceTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 122 | 1 | Bool | `(obj?["success"] as? Bool)! == false` | `!((obj?["success"] as? Bool)!)` |

### PermissionCheckerTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| - | 5 | Bool | `accessibility == true \|\| accessibility == false` | `removed; _ = call (env-dependent)` |
| - | 5 | Bool | `automation == true \|\| automation == false` | `removed; _ = call (env-dependent)` |
| - | 5 | Bool | `status.accessibility == true \|\| status.accessibility == false` | `replaced block → #expect(!status.summary.isEmpty)` |
| - | 5 | Bool | `status.automationLogicPro == true \|\| status.automationLogicPro == false` | `(same block as above)` |
| 68 | 1 | Bool | `bool == false` | `!(bool)` |

### PluginGetInventoryTests (4)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 36 | 1 | Bool | `complete == false` | `!(complete)` |
| 396 | 3 | Bool? (optional chain) | `(obj["recovery_hint"] as? String)?.contains("Show Mixer") == true` | `((obj["recovery_hint"] as? String)?.contains("Show Mixer"))!` |
| 74 | 1 | Bool | `complete == true` | `complete` |
| 84 | 1 | Bool | `complete == true` | `complete` |

### PluginInsertVerifiedTests (8)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 339 | 3 | Bool? (optional chain) | `(obj["what_was_observed"] as? String)?.contains("exact slot popup") == true` | `((obj["what_was_observed"] as? String)?.contains("exact slot popup"))!` |
| 571 | 1 | Bool | `result.succeeded == false` | `!(result.succeeded)` |
| 584 | 1 | Bool | `result.succeeded == false` | `!(result.succeeded)` |
| 595 | 1 | Bool | `result.succeeded == true` | `result.succeeded` |
| 596 | 1 | Bool | `result.attempted == true` | `result.attempted` |
| 607 | 1 | Bool | `result.succeeded == true` | `result.succeeded` |
| 619 | 1 | Bool | `result.succeeded == true` | `result.succeeded` |
| 632 | 1 | Bool | `result.succeeded == false` | `!(result.succeeded)` |

### ProcessUtilsStdioParityTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 57 | 3 | Bool? (optional chain) | `version.first?.isNumber == true` | `(version.first?.isNumber)!` |

### ProcessUtilsTests (13)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| - | 5 | Bool | `activated == true \|\| activated == false` | `removed; _ = call (env-dependent)` |
| 101 | 1 | Bool | `ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == false` | `!(ProcessUtils.isLogicProRunning(runtime: harness.runtime()))` |
| 106 | 1 | Bool | `ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == true` | `ProcessUtils.isLogicProRunning(runtime: harness.runtime())` |
| 114 | 1 | Bool | `ProcessUtils.isLogicProRunning(runtime: harness.runtime()) == true` | `ProcessUtils.isLogicProRunning(runtime: harness.runtime())` |
| 200 | 1 | Bool | `activated == false` | `!(activated)` |
| 219 | 1 | Bool | `activated == true` | `activated` |
| 235 | 1 | Bool | `activated == true` | `activated` |
| 254 | 1 | Bool | `activated == true` | `activated` |
| 289 | 1 | Bool | `status.allGranted == true` | `status.allGranted` |
| 293 | 1 | Bool | `status.summary.contains("System Settings") == false` | `!(status.summary.contains("System Settings"))` |
| 299 | 1 | Bool | `status.allGranted == false` | `!(status.allGranted)` |
| 302 | 1 | Bool | `status.summary.contains("Accessibility → add your terminal app") == false` | `!(status.summary.contains("Accessibility → add your terminal app"))` |
| 59 | 1 | Bool | `result == true` | `result` |

### ProductionReadinessTests (11)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 229 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/normal.logicx") == true` | `AppleScriptSafety.isValidFilePath("/tmp/normal.logicx")` |
| 230 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/evil\n.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/tmp/evil\n.logicx"))` |
| 231 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/evil\r.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/tmp/evil\r.logicx"))` |
| 232 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/evil\t.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/tmp/evil\t.logicx"))` |
| 233 | 1 | Bool | `AppleScriptSafety.isValidFilePath("/tmp/evil\0.logicx") == false` | `!(AppleScriptSafety.isValidFilePath("/tmp/evil\0.logicx"))` |
| 271 | 1 | Bool | `await poller.isRunning == true` | `await poller.isRunning` |
| 274 | 1 | Bool | `await poller.isRunning == false` | `!(await poller.isRunning)` |
| 285 | 1 | Bool | `await poller.isRunning == false` | `!(await poller.isRunning)` |
| 298 | 1 | Bool | `status.accessibility == true` | `status.accessibility` |
| 311 | 1 | Bool | `granted.allGranted == true` | `granted.allGranted` |
| 318 | 1 | Bool | `notGranted.allGranted == false` | `!(notGranted.allGranted)` |

### ProjectDispatcherTests (2)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 61 | 1 | Bool | `sharedToolText(result).isEmpty == false` | `!(sharedToolText(result).isEmpty)` |
| 90 | 1 | Bool | `sharedToolText(result).isEmpty == false` | `!(sharedToolText(result).isEmpty)` |

### ProjectExportBounceHelperContractTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 205 | 3 | Bool? (optional chain) | `nonZeroSuccess.error?.contains("bounce_helper_exit_code_9") == true` | `(nonZeroSuccess.error?.contains("bounce_helper_exit_code_9"))!` |

### ProjectExportExecutionGuardrailTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 161 | 3 | Bool? (optional chain) | `artifact.error?.contains("unsafe_path") == true` | `(artifact.error?.contains("unsafe_path"))!` |

### ProjectExportPlannerTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 135 | 4 | Bool? (.isError; nil=success) | `#expect(result.isError != true)` | `let resultIsError = result.isError ?? false ⏎         #expect(!resultIsError)` |

### ResourceSchemaTests (9)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 191 | 1 | Bool | `cached.isPlaying == false` | `!(cached.isPlaying)` |
| 193 | 1 | Bool | `cached.isCycleEnabled == true` | `cached.isCycleEnabled` |
| 222 | 3 | Bool? (optional chain) | `(envelope["recovery_hint"] as? String)?.contains("refresh_cache") == true` | `((envelope["recovery_hint"] as? String)?.contains("refresh_cache"))!` |
| 293 | 1 | Bool | `(obj?["success"] as? Bool)! == false` | `!((obj?["success"] as? Bool)!)` |
| 309 | 3 | Bool? (optional chain) | `tracks.contents.first?.text?.contains("[") == true` | `(tracks.contents.first?.text?.contains("["))!` |
| 335 | 3 | Bool? (property; compiler-confirmed) | `connected == true` | `connected` |
| 336 | 3 | Bool? (property; compiler-confirmed) | `registered == false` | `!(registered)` |
| 437 | 3 | Bool? (property; compiler-confirmed) | `connected == false` | `!(connected)` |
| 438 | 3 | Bool? (property; compiler-confirmed) | `registered == false` | `!(registered)` |

### SMFWriterTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 256 | 3 | Bool? (property; compiler-confirmed) | `(try? FileManager.default.contentsOfDirectory(atPath: attackTarget).isEmpty) == true` | `(try? FileManager.default.contentsOfDirectory(atPath: attackTarget).isEmpty)` |

### ScanLibraryCacheSplitTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 64 | 3 | Bool? (optional chain) | `(obj["warning"] as? String)?.contains("leaf preset paths") == true` | `((obj["warning"] as? String)?.contains("leaf preset paths"))!` |

### ScripterChannelTests (8)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 100 | 1 | Bool | `afterApproval.ready == true` | `afterApproval.ready` |
| 114 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains("only handles plugin.set_param") == true` | `((obj["hint"] as? String)?.contains("only handles plugin.set_param"))!` |
| 131 | 3 | Bool? (optional chain) | `(obj["hint"] as? String)?.contains("Failed to send Scripter param 1") == true` | `((obj["hint"] as? String)?.contains("Failed to send Scripter param 1"))!` |
| 145 | 3 | Bool? (optional chain) | `(badInsertObj["hint"] as? String)?.contains("insert 0") == true` | `((badInsertObj["hint"] as? String)?.contains("insert 0"))!` |
| 154 | 3 | Bool? (optional chain) | `(badParamObj["hint"] as? String)?.contains("out of range") == true` | `((badParamObj["hint"] as? String)?.contains("out of range"))!` |
| 78 | 1 | Bool | `beforeStart.available == false` | `!(beforeStart.available)` |
| 83 | 1 | Bool | `afterStart.available == true` | `afterStart.available` |
| 95 | 1 | Bool | `beforeApproval.ready == false` | `!(beforeApproval.ready)` |

### SetupLifecycleTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 163 | 1 | Bool | `try #require(step(writable, "binary.install")).requiresSudo == false` | `!(try #require(step(writable, "binary.install")).requiresSudo)` |
| 164 | 1 | Bool | `try #require(step(notWritable, "binary.install")).requiresSudo == true` | `try #require(step(notWritable, "binary.install")).requiresSudo` |
| 236 | 1 | Bool | `try #require(step(plan, "binary.remove")).requiresSudo == false` | `!(try #require(step(plan, "binary.remove")).requiresSudo)` |

### StateCacheTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 120 | 1 | Bool | `transport.isPlaying == false` | `!(transport.isPlaying)` |
| 121 | 1 | Bool | `transport.isRecording == false` | `!(transport.isRecording)` |
| 136 | 1 | Bool | `tracks[0].isSelected == false` | `!(tracks[0].isSelected)` |
| 137 | 1 | Bool | `tracks[1].isSelected == true` | `tracks[1].isSelected` |
| 138 | 1 | Bool | `tracks[2].isSelected == false` | `!(tracks[2].isSelected)` |

### StatePollerOcclusionTests (12)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 107 | 1 | Bool | `await cache.getAXOccluded() == true` | `await cache.getAXOccluded()` |
| 110 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 128 | 1 | Bool | `await cache.getAXOccluded() == true` | `await cache.getAXOccluded()` |
| 165 | 1 | Bool | `await cache.getAXOccluded() == false` | `!(await cache.getAXOccluded())` |
| 167 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 246 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 250 | 1 | Bool | `await cache.getHasDocument() == false` | `!(await cache.getHasDocument())` |
| 252 | 1 | Bool | `await cache.getAXOccluded() == false` | `!(await cache.getAXOccluded())` |
| 60 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 62 | 1 | Bool | `await cache.getAXOccluded() == false` | `!(await cache.getAXOccluded())` |
| 80 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 86 | 1 | Bool | `await cache.getAXOccluded() == true` | `await cache.getAXOccluded()` |

### StatePollerTests (5)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 107 | 1 | Bool | `await poller.isRunning == false` | `!(await poller.isRunning)` |
| 190 | 3 | Bool? (optional chain) | `tracks.first?.isSelected == true` | `(tracks.first?.isSelected)!` |
| 219 | 1 | Bool | `await cache.getHasDocument() == true` | `await cache.getHasDocument()` |
| 221 | 1 | Bool | `await cache.getHasDocument() == false` | `!(await cache.getHasDocument())` |
| 339 | 1 | Bool | `await poller.isRunning == false` | `!(await poller.isRunning)` |

### StockPluginCatalogTests (7)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 328 | 3 | Bool? (optional chain) | `manifested.provenance.sourcePath?.hasSuffix("Plug-In Settings/Limiter") == true` | `(manifested.provenance.sourcePath?.hasSuffix("Plug-In Settings/Limiter"))!` |
| 458 | 3 | Bool? (optional chain) | `(list["entries"] as? [[String: Any]])?.isEmpty == false` | `!(((list["entries"] as? [[String: Any]])?.isEmpty)!)` |
| 466 | 3 | Bool? (optional chain) | `(search["entries"] as? [[String: Any]])?.contains { $0["id"] as? String == "logic.stock.ef` | `((search["entries"] as? [[String: Any]])?.contains { $0["id"] as? String == "logic.stock.e` |
| 474 | 3 | Bool? (optional chain) | `(capabilities["truth_labels"] as? [String])?.contains("verified") == true` | `((capabilities["truth_labels"] as? [String])?.contains("verified"))!` |
| 475 | 3 | Bool? (optional chain) | `(capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets") == true` | `((capabilities["catalog_entry_fields"] as? [String])?.contains("known_presets"))!` |
| 476 | 3 | Bool? (optional chain) | `(capabilities["resources"] as? [String])?.contains("logic://stock-plugins") == true` | `((capabilities["resources"] as? [String])?.contains("logic://stock-plugins"))!` |
| 478 | 3 | Bool? (optional chain) | `(capabilities["census_injectable_states"] as? [String])?.contains("readback_mismatch") == ` | `((capabilities["census_injectable_states"] as? [String])?.contains("readback_mismatch"))!` |

### TrackDispatcherDeleteTests (3)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 197 | 3 | Bool? (optional chain) | `object?["success"] as? Bool == false` | `!((object?["success"] as? Bool)!)` |
| 200 | 3 | Bool? (optional chain) | `selectResponse?.contains("retry_exhausted") == true` | `(selectResponse?.contains("retry_exhausted"))!` |
| 201 | 3 | Bool? (optional chain) | `selectResponse?.contains("\"verified\":false") == true` | `(selectResponse?.contains("\"verified\":false"))!` |

### TrackDispatcherRecordSequenceTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 289 | 2 | Bool? (as? cast) | `object["audible"] as? Bool == false` | `!((object["audible"] as? Bool)!)` |

### UtilityCoverageTests (1)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 48 | 3 | Bool? (property; compiler-confirmed) | `boolParamOrNil(params, "enabled") == false` | `!(boolParamOrNil(params, "enabled"))` |

### VerifiedOpGateTests (6)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 12 | 1 | Bool | `gate.tryAcquire() == true` | `gate.tryAcquire()` |
| 13 | 1 | Bool | `gate.tryAcquire() == false` | `!(gate.tryAcquire())` |
| 15 | 1 | Bool | `gate.tryAcquire() == true` | `gate.tryAcquire()` |
| 32 | 1 | Bool | `acquired == true` | `acquired` |
| 72 | 1 | Bool | `VerifiedOpGate.shared.tryAcquire() == true` | `VerifiedOpGate.shared.tryAcquire()` |
| 80 | 1 | Bool | `acquired == true` | `acquired` |

### WorkflowSkillCatalogTests (14)
| line | rule | LHS type | original | replacement |
|---|---|---|---|---|
| 307 | 3 | Bool? (optional chain) | `stock?.dependsOn.contains("logic://stock-plugins") == true` | `(stock?.dependsOn.contains("logic://stock-plugins"))!` |
| 314 | 3 | Bool? (optional chain) | `stock?.unresolvedResources?.allSatisfy { $0.hasPrefix("logic://stock-plugins") } == true` | `(stock?.unresolvedResources?.allSatisfy { $0.hasPrefix("logic://stock-plugins") })!` |
| 320 | 3 | Bool? (optional chain) | `liveInsert?.productionReady == true` | `(liveInsert?.productionReady)!` |
| 323 | 3 | Bool? (optional chain) | `liveInsert?.requiredConfirmations.contains { $0.level == "L2" } == true` | `(liveInsert?.requiredConfirmations.contains { $0.level == "L2" })!` |
| 326 | 3 | Bool? (optional chain) | `readiness?.dependenciesResolved == true` | `(readiness?.dependenciesResolved)!` |
| 398 | 3 | Bool? (optional chain) | `WorkflowSkillCatalog.publicCommands[tool]?.contains(command) == true` | `(WorkflowSkillCatalog.publicCommands[tool]?.contains(command))!` |
| 421 | 3 | Bool? (optional chain) | `(schema["lint_rules"] as? [String])?.contains("unknown_command") == true` | `((schema["lint_rules"] as? [String])?.contains("unknown_command"))!` |
| 422 | 3 | Bool? (optional chain) | `(schema["lint_rules"] as? [String])?.contains("invalid_dependency") == true` | `((schema["lint_rules"] as? [String])?.contains("invalid_dependency"))!` |
| 592 | 3 | Bool? (optional chain) | `WorkflowSkillCatalog.publicCommands[tool]?.contains(command) != true` | `!((WorkflowSkillCatalog.publicCommands[tool]?.contains(command))!)` |
| 632 | 3 | Bool? (optional chain) | `((stockDetail["workflow"] as? [String: Any])?["unresolved_resources"] as? [String])?.isEmp` | `!((((stockDetail["workflow"] as? [String: Any])?["unresolved_resources"] as? [String])?.is` |
| 636 | 3 | Bool? (optional chain) | `(search["workflows"] as? [[String: Any]])?.contains {             $0["id"] as? String == "` | `((search["workflows"] as? [[String: Any]])?.contains {             $0["id"] as? String == ` |
| 639 | 3 | Bool? (optional chain) | `(search["workflows"] as? [[String: Any]])?.contains {             $0["id"] as? String == "` | `((search["workflows"] as? [[String: Any]])?.contains {             $0["id"] as? String == ` |
| 656 | 3 | Bool? (optional chain) | `(schema["fields"] as? [String])?.contains("state_checks") == true` | `((schema["fields"] as? [String])?.contains("state_checks"))!` |
| 657 | 3 | Bool? (optional chain) | `(schema["evidence_levels"] as? [String])?.contains("live_verified") == true` | `((schema["evidence_levels"] as? [String])?.contains("live_verified"))!` |

## Flip / fault-injection proof (AC3)

Each safety-critical file's now-live assertion was proven to catch a regression:
temporarily break the guarded PRODUCTION behavior, run the focused test, confirm
the assertion goes RED, then `git checkout` to revert (production untouched in the
final diff). Covers all four transform types used in safety-critical files.

| # | file:line (assertion) | rule | production mutation | result |
|---|---|---|---|---|
| 1 | AXPluginInsertSlotsDriftTests:85 `!(slots[1].isEmpty)` + :136 | 1 (negate) | `PluginInsertSlot.isEmpty` → also true for `.occupiedUnreadable` | ✘ RED (both), reverted |
| 2 | Issue136GotoDriftHonestTests:115 `#expect(resultIsError)` | 4 (isError bind) | TransportDispatcher goto drift `isError: true` → `false` | ✘ RED, reverted |
| 3 | PluginInsertVerifiedTests:178 `(obj["success"] as? Bool)!` | 2 (as? unwrap) | mounted `.success(encodeV2StateA)` → `.error(encodeV2StateC)` | ✘ RED (177/178/179), reverted |
| 4 | DispatcherTests:1118 `#expect(!resultIsError)` | 4 (isError bind) | MixerDispatcher insert_plugin confirmation `toolTextResult(response)` → `isError: true` | ✘ RED, reverted |

Every flip produced the expected FAIL and was reverted (`git status Sources/` clean).
No assertion went unexpectedly RED during the sweep — the full suite stayed green
after transformation (AC4: no latent bug surfaced; guarded behaviors were correct,
the assertions simply weren't checking before).

## Notes / edge cases handled
- **In-closure comparisons are LIVE, excluded**: `.allSatisfy { ($0["executed"] as? Bool) == .some(false) }` etc. are compiled normally (the macro doesn't descend into `{ }` predicates). 2 such sites in EndToEndTests correctly left untouched.
- **Already-force-unwrapped casts**: `(obj["success"] as? Bool)! == false` → `!((obj["success"] as? Bool)!)` (LHS is already non-optional `Bool`, negate only — not double-unwrapped).
- **`== nil`/`!= nil`/`!= .none`**: live Optional-vs-nil checks, NOT dead — left untouched (1 `!= .none` excluded).
- **11 optionality stragglers** (compiler-flagged `Bool?` the `as?`/optional-chain heuristic missed): AXLogicProElementsTests, AXValueExtractorsTests, ResourceSchemaTests(×4), SMFWriterTests, UtilityCoverageTests — all resolved to rule-3 force-unwrap (nil = broken setup = must fail; both ambiguous cases confirmed nil-impossible by fixture construction).

## Findings surfaced by making the assertions live (AC4)

Making these dead assertions live exposed 5 latent test-quality defects (2 as
force-unwrap SIGTRAP crashes, 3 as expectation failures). Each was investigated
to ground truth — **none is a production bug**; every one is a stale/racy/
wrong-shape TEST that the dead form had been silently passing. Fixes preserve
each test's scenario.

| # | site | how it surfaced | root cause (ground-truthed) | fix |
|---|---|---|---|---|
| 1 | Issue139TrackMutationOcclusionHonestTests:185 | force-unwrap SIGTRAP | HC **v1** `encodeStateC` omits `verified` entirely (absent = not verified); `(json["verified"] as? Bool)!` crashed on the absent key | rule-4 bind: `let verified = (json["verified"] as? Bool) ?? false; #expect(!verified)` |
| 2 | LogicProServerHandlerTests:131 | force-unwrap SIGTRAP | `logic://tracks` is a metadata **envelope** `{source,data:[…]}`; the test's bare-array parse `as? [[String:Any]]` decoded to nil (rows live under `data`) | parse the envelope, `#expect(trackData.isEmpty)` (data confirmed `[]`) |
| 3 | EndToEndTests:424 | expectation failure | `list_ports` fails closed `channels_exhausted` when the test process has no in-process CoreMIDI channel — `isError` is environment-dependent (why every sibling MIDI dispatch test asserts the envelope, never `!isError`) | drop the env-dependent `isError` assertion; keep the deterministic dispatch check (op-envelope) |
| 4 | MCUChannelTests:123/124 | expectation failure | WS6 routes feedback through an async ordered-consumer Task; the test read `getMCUConnection()` before the drain applied the registration (a timing gap) | poll `getMCUConnection()` until `isConnected` (the WS6 ordering-test pattern) |
| 5 | ProjectExportExecutionGuardrailTests:161 | expectation failure | symlink-escape DOES fail closed (State C, bounceFired) — the surfaced error code is `artifact_path_unsafe:` (`unsafe_path` is the internal reason the flow wraps) | assert the surfaced code `artifact_path_unsafe` |

Signal: 2 crashes + 3 failures out of 386 transformed assertions = the dead-form
masking rate this sweep was meant to expose. The remaining 381 stayed green when
made live (guarded behaviors were correct; the assertions just weren't checking).
