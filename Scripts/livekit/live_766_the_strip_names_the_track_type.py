"""Live proof that `observed_track_type` comes from the channel strip, and stops where the strip does.

Usage:  LPM_EVIDENCE_ROOT=/abs/path/outside/repo \
        python3 live_766_the_strip_names_the_track_type.py <worktree> <full-40-char-head-sha>

WHAT WAS WRONG
--------------
`inferTrackType` reads the track HEADER, and the header carries no type signal: all seven headers in
a project produce identical token sets, because the Input Monitoring button's help names an audio
track and a software instrument track in the same sentence. It answered `audio` for everything; the
first half of #766 made it answer `unknown` for everything instead, which is true and useless.

WHAT THIS CHECKS
----------------
The inspector channel strip Logic builds for the SELECTED track does carry a signal, for two of the
four kinds. After `create_*` the new track is already selected, so the read costs no selection
change. Measured 2026-09-09 on Logic 12.3 (6674), en:

    create_audio          -> Input slot            -> audio
    create_external_midi  -> Assign control, no output slot -> external_midi
    create_instrument     -> MIDI Effect slot      -> instrument FAMILY, so `unknown`
    create_drummer        -> MIDI Effect slot      -> IDENTICAL to the instrument, so `unknown`

THE COUNTEREXAMPLE
------------------
The pre-fix reading verbatim: every create answers `unknown` with
`track_type_verification_source: "observed_header"`. A run where the two readable kinds still say
`unknown`, or where the two unreadable ones claim a narrow type, is that reading again.

This is a `non_ui` run: the subject is a published envelope field, not a rectangle.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence as E  # noqa: E402

if len(sys.argv) < 3 or len(sys.argv[2]) != 40:
    print(__doc__)
    sys.exit(1)

WT, HEAD = os.path.abspath(sys.argv[1]), sys.argv[2]
E.REPO = WT
E.BIN = f"{WT}/.build/release/LogicProMCP"
ev = E.Evidence(HEAD, os.environ["LPM_EVIDENCE_ROOT"], surface="non_ui")

d = E.Driver()
readings = {}
try:
    for command in ("create_audio", "create_external_midi", "create_instrument", "create_drummer"):
        body = d.tool("logic_tracks", command) or {}
        readings[command] = {
            "observed_track_type": body.get("observed_track_type"),
            "source": body.get("track_type_verification_source"),
            "requested": body.get("requested_track_type"),
            "state": body.get("state"),
        }
finally:
    d.close()

ev.falsifiable(
    "766/the-strip-names-the-two-kinds-it-can-read",
    # Compared against the operation's OWN `requested_track_type` rather than against a spelling
    # written in here. Two reasons and the second is the stronger one: a literal `"audio"` is a
    # token this repo also has localized UI variants for, and pinning "observed equals requested" is
    # the actual contract — the field exists to say whether what was created is what was asked for.
    lambda o: (o["create_audio"]["observed_track_type"] == o["create_audio"]["requested"]
               and o["create_audio"]["source"] == "inspector_channel_strip"
               and o["create_external_midi"]["observed_track_type"]
                   == o["create_external_midi"]["requested"]
               and o["create_external_midi"]["source"] == "inspector_channel_strip"),
    readings,
    {"create_audio": {"observed_track_type": "unknown", "requested": "audio",
                      "source": "observed_header"},
     "create_external_midi": {"observed_track_type": "unknown", "requested": "external_midi",
                              "source": "observed_header"}},
    "an audio track and an external MIDI track each report their own type, and the field says the "
    "strip is where it came from. The counterexample is the reading before this change, where both "
    "answered `unknown` from the header",
    mutation="return `.undetermined` from `AXLogicProElements.reading(fromSlotKinds:)`",
)

ev.falsifiable(
    "766/the-instrument-family-is-refused-rather-than-guessed",
    lambda o: (o["create_instrument"]["observed_track_type"] == "unknown"
               and o["create_drummer"]["observed_track_type"] == "unknown"
               and o["create_instrument"]["source"] == "inspector_channel_strip_instrument_family"
               and o["create_drummer"]["source"] == "inspector_channel_strip_instrument_family"),
    readings,
    {"create_instrument": {"observed_track_type": "software_instrument",
                           "source": "inspector_channel_strip"},
     "create_drummer": {"observed_track_type": "software_instrument",
                        "source": "inspector_channel_strip"}},
    "a software instrument and a drummer both answer `unknown`, and the source says the strip was "
    "READ and reported a family rather than that no strip answered. The counterexample is the "
    "narrowing this change refuses: a drummer strip is identical to an instrument's, so any rule "
    "that names one names the other, and it would be wrong for every drummer track",
    mutation="return `.type(.softwareInstrument)` for the MIDI-effect case",
)

ev.check("766/every-create-actually-ran",
         all(r["state"] == "A" for r in readings.values()),
         "all four creates verified state A, so the type fields describe tracks that exist rather "
         "than operations that failed",
         ", ".join(f"{k}={v['state']}" for k, v in readings.items()), None)

ev.write()
print(__doc__)
