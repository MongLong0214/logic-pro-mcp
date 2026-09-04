# Surface taxonomy

The observation records are building toward one thing: a measured map of Logic's UI/UX, surface by
surface, so that when the application changes we know what changed and what was standing on it.

A map needs a coordinate system. Every record carries a `surface` — a dotted path from this table —
so that with a hundred records it is still possible to ask "what do we know about the mixer", and the
harder question, **"what have we never measured?"**

## The surfaces

| surface | what it covers |
|---|---|
| `arrange.track_headers` | the track rail: names, numbers, selection, stacks, disclosure |
| `arrange.regions` | regions in the arrangement area |
| `arrange.menus` | Track / Edit / Navigate menus acting on the arrangement |
| `arrange.transport` | transport bar, playhead, tempo/key display |
| `mixer.channel_strips` | strips, their controls, ordering |
| `mixer.inserts` | insert slots, the plug-in popup, insert state |
| `mixer.routing` | inputs, outputs, sends, busses |
| `plugin.window` | the editor window frame, view switcher, presets |
| `plugin.controls_view` | Logic's host-provided Controls table |
| `plugin.native_view` | a plug-in's own UI |
| `editor.piano_roll` | the Piano Roll |
| `editor.event_list` | the Event List |
| `editor.audio_track` | the Audio Track Editor, including Flex |
| `editor.step` | the Step Sequencer |
| `library.patches` | the Library browser |
| `project.lifecycle` | new / open / save / close, and their panels |
| `project.export` | bounce and export panels |
| `system.midi` | CoreMIDI endpoints, MCU, control surfaces |
| `system.preferences` | Settings and Key Commands |

Add a row before using a new value. A taxonomy that grows silently per record is a list of strings,
not a map — `Scripts/check-observation-records.py` refuses a `surface` that is not in this table.

## Coverage

```
Scripts/observations-status.py --coverage
```

prints each surface with the records that touch it and, more usefully, the surfaces with none.
**A surface with no records is not a surface that works. It is one nobody has looked at**, and the
report says so in those words rather than leaving a blank to be read as a pass.

## Granularity

One record answers **one question about one surface**. Not "the mixer", but "can an insert slot's
plug-in popup be opened without coordinates". Small records supersede cleanly; a record that answers
five questions goes stale as a block when one of the five changes.
