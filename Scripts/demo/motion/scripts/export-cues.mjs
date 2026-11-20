// Prints the film's sound cues as JSON for the audio step: structure from src/timeline.ts, real write times from the take.
import { readFileSync } from "node:fs";
import { SONG, sfxSong, social, bar, vOfFootage } from "../src/timeline.ts";

const session = JSON.parse(readFileSync(new URL("../public/data/session.json", import.meta.url)));
const f = session.film;
const P = vOfFootage(f.musicStart);
const writes = f.events.filter((e) => e.kind === "tool" && !/\.(play|stop)$/.test(e.call)).map((e) => vOfFootage(e.t));
const sfx = [[0.0, "riser"], [P - 0.95, "riser"], [P - 0.02, "boom"], ...sfxSong.map(([t, k]) => [t + P, k]), ...writes.map((v) => [v, "tick"])].sort((a, b) => a[0] - b[0]);
const total = P + SONG;
// social cut on its own clock
let s = 0;
const segs = [];
for (const seg of social.segments) {
  if (seg.kind === "pre") { segs.push({ kind: "pre", s0: s, len: P }); s += P; }
  else { segs.push({ kind: "song", s0: s, len: seg.len, from: seg.from }); s += seg.len; }
}
console.log(JSON.stringify({ P, total, song: SONG, sfx, social: { segments: segs, total: s } }, null, 1));
