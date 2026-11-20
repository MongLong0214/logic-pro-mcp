// One source of truth for the film's structure. Times are seconds of the finished video; the music bed
// (Logic's own output of the song, 112 BPM, bar = 2.143 s) runs from 0, so scene cuts land on bars.
// scripts/export-cues.ts reads this same file to place sound-design hits, so picture and sound cannot drift.
export const BPM = 112;
export const BAR = (60 / BPM) * 4;
export const bar = (n: number) => (n - 1) * BAR; // start of 1-based bar n

export const TOTAL = bar(36) + BAR + 2.6; // song ends at the end of bar 36 (rings out), plus the CTA tail

export type SceneId = "hook" | "problem" | "reveal" | "read" | "tempo" | "build" | "mix" | "verify" | "speed" | "close";

export const scenes: Record<SceneId, { from: number; to: number }> = {
  hook: { from: 0, to: bar(3) },
  problem: { from: bar(3), to: bar(5) },
  reveal: { from: bar(5), to: bar(7) + 0.4 },
  read: { from: bar(7) + 0.4, to: bar(9) },
  tempo: { from: bar(9), to: bar(11) },
  build: { from: bar(11), to: bar(17) },
  mix: { from: bar(17), to: bar(21) },
  verify: { from: bar(21), to: bar(25) },
  speed: { from: bar(25), to: bar(29) },
  close: { from: bar(29), to: TOTAL },
};

// Sound-design hits: [time s, kind]. Kinds are synthesised by scripts/sfx.sh (whoosh, tick, ding, riser, boom).
export const sfx: Array<[number, "whoosh" | "tick" | "ding" | "riser" | "boom"]> = [
  [bar(3) - 0.05, "whoosh"],
  [bar(5) - 0.9, "riser"],
  [bar(5), "boom"],
  [scenes.read.from, "whoosh"],
  [scenes.tempo.from, "whoosh"],
  [scenes.build.from, "whoosh"],
  [scenes.mix.from, "whoosh"],
  [scenes.verify.from, "whoosh"],
  [scenes.speed.from, "whoosh"],
  [scenes.close.from - 0.1, "whoosh"],
];

// 26 s cut for social and the README GIF: [video start, video end, music start]. The audio script crossfades
// between these excerpts of the same song; scene components take the matching footage offsets.
export const social = {
  hook: { v: [0, 3.4], a: 0 },
  reveal: { v: [3.4, 8.0], a: bar(5) - 0.6 },
  drop: { v: [8.0, 20.0], a: bar(13) },
  close: { v: [20.0, 26.0], a: bar(29) },
  total: 26.0,
};
