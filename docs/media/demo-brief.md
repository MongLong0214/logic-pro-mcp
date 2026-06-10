# README Demo Brief

## Replacement Standard

The README hero media must show the real product surface. The current cut is a
cropped screen recording of Logic Pro 12.2 during live playback, with no
synthetic DAW arrangement, no painted track rows, and no fake project surface.
The only visible Logic content is the actual Logic window capture.

## Audience

- Logic Pro users who want Claude, Cursor, or a custom MCP client to operate a
  real DAW session.
- MCP client authors who need to know the server exposes typed tools and read
  resources, not prompt-only recipes.
- Maintainers/reviewers checking whether the project is honest about safety and
  verification.

## Narrative

| Time | Scene | User question answered | Required visible information |
|------|-------|------------------------|------------------------------|
| 0-6s | Actual Logic playback | Is this the real Logic Pro interface? | Live arrange window, moving playhead, meters, actual track headers, actual MIDI regions, and Logic's own transport UI. |

## Quality bar

- Use actual Logic Pro capture as the hero, not a recreated DAW mockup.
- Do not render synthetic tracks, fake region rows, fake project names, or fake
  resource panels over the Logic window.
- Text must still be readable after the README GIF is scaled to 920px wide.
- Keep the cut short enough for the README; the current cut is 6 seconds.
- Do not show debug badges, bottom navigation rails, or internal QA labels.
- The video must not claim a capability without matching live readback or repo
  evidence.
- The MP4 is a live capture artifact. `docs/media/render-demo.py` validates the
  MP4 and regenerates the GIF/thumbnail derivatives from it.

## Verification checklist

- `python3 docs/media/render-demo.py` validates the MP4 and regenerates GIF and thumbnail.
- `ffprobe` confirms the MP4 duration, dimensions, frame rate, and frame count.
- `sips` confirms GIF and thumbnail dimensions.
- Sampled frames confirm the hero is real Logic UI with playhead and meter movement.
- README links point to tracked media files.
