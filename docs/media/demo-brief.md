# README Demo Brief

## Replacement Standard

The README hero media must behave like proof, not a presentation. The cut now
shows a complete chain:

- MCP client prompt and typed tool calls.
- Captured Logic Pro project state changing from source material to MIDI.
- Resource readback proving the post-write state.
- Current verification counts without implying broader coverage than the repo
  evidence supports.

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
| 0-6s | Prompt to tools | What does the agent actually call? | Prompt, health gate, tempo set, record_sequence batch, save_as verification. |
| 6-12s | Logic mutates | Did Logic visibly change? | Captured Logic arrangement, highlighted track/region surface, playhead motion, write-path notes. |
| 12-18s | Readback proof | How is success verified? | `logic://tracks`, `logic://project/info`, confirmed/uncertain/failed outcome line, current evidence counts. |

## Quality bar

- Use captured Logic Pro frames instead of a single fixed screenshot.
- Text must still be readable after the README GIF is scaled to 920px wide.
- Keep the cut to 18 seconds and 3 scenes.
- Do not show debug badges, bottom navigation rails, or internal QA labels.
- Every scene must carry concrete product information, not abstract marketing copy.
- The video must not claim a capability without a matching README/source-tree
  surface.
- MP4, GIF, thumbnail, and renderer must be reproducible from
  `docs/media/render-demo.py`.

## Verification checklist

- `python3 docs/media/render-demo.py` regenerates MP4, GIF, and thumbnail.
- `ffprobe` confirms the MP4 duration, dimensions, frame rate, and frame count.
- `sips` confirms GIF and thumbnail dimensions.
- A frame sheet covers the full timeline for visual review.
- Consecutive sampled frames confirm the background crop is locked.
- README links point to tracked media files.
