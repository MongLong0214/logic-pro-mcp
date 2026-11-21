// Prints the film's sound cues as JSON for the audio step: the plan from src/timeline.ts, real call times from the take.
//   node --experimental-strip-types motion/scripts/export-cues.mjs > work/cues.json
import { readFileSync } from "node:fs";
import { plan } from "../src/timeline.ts";

const session = JSON.parse(readFileSync(new URL("../public/data/session.json", import.meta.url)));
const p = plan(session);
const tool = p.steps.filter((s) => s.kind === "tool");
const sfx = [];
for (const s of tool) sfx.push([s.tauEnd, "tick"]); // one soft tick when Logic answers each call
const drop = tool.find((s) => s.track_name === "Drums" && s.call.endsWith("set_volume") && !s.noop); // the fader entrance, not a pan
if (drop) sfx.push([drop.tau - 0.9, "riser"]);
if (p.proof) sfx.push([p.proof.from - 0.1, "whoosh"]);
sfx.push([p.end.from - 0.05, "boom"]);
sfx.push([p.end.from - 0.25, "whoosh"]);
sfx.sort((a, b) => a[0] - b[0]);
console.log(JSON.stringify({
  F0: p.F0, total: p.total, musicTau: p.musicTau, sessionEnd: p.sessionEnd, end: p.end, proof: p.proof,
  stopTau: session.film.stopAt != null ? session.film.stopAt - p.F0 : null,
  entrances: tool.filter((s) => s.call.endsWith("set_volume") && !s.noop && s.before === 0).map((s) => ({ tau: s.tau, tauEnd: s.tauEnd, track: s.track_name })),
  sfx, social: { segments: p.social, total: p.social[p.social.length - 1].s0 + p.social[p.social.length - 1].len },
}, null, 1));
