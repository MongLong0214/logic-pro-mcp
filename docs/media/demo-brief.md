# README Demo Brief

## Verdict on the discarded cut

The previous cut is rejected because it behaves like a mood reel. It shows a
Logic Pro background and abstract trust language, but it does not answer the
questions a first-time README visitor needs answered before trying the project:

- What is this project, in one sentence?
- How do I connect it to an MCP client?
- What can an agent actually do inside Logic Pro?
- Why is this safer than screen macros?
- What evidence proves the repo is not just a concept demo?

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
| 0-4s | What it is | Why does this repo exist? | Logic has no first-party agent API; Logic Pro MCP is a typed MCP control plane. |
| 4-10s | Connect | How do I use it? | Homebrew install, MCP client registration, required macOS permissions. |
| 10-17s | Control | What does it actually do? | Real tool calls for project creation, MIDI sequence writing, instrument routing, guarded plugin insertion. |
| 17-23s | Safety | Why not just use macros? | Channel routing, confirmation gates, fail-closed/uncertain outcome handling. |
| 23-29s | Readback | How can an agent verify results? | `logic://...` resources, live readback examples, confirmed/uncertain/failed outcome line. |
| 29-34s | Proof | Why should I trust it? | Tool/resource/template counts, Swift tests, strict live checks, stable release line. |

## Quality bar

- No camera pan, zoom, or crop drift; the Logic Pro screenshot must remain a
  fixed frame.
- Text must still be readable after the README GIF is scaled to 920px wide.
- Every scene must carry concrete product information, not abstract marketing
  copy.
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
