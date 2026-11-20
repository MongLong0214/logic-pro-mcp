// The film's structure. No imports so scripts/export-cues.mjs can read it with plain node.
// Two clocks: v = seconds of the finished video, t = seconds of the song (bar 1 = t 0, a bar is 2.0 s at 120 BPM).
export const BPM = 120;
export const BAR = (60 / BPM) * 4;
export const bar = (n: number) => (n - 1) * BAR;
export const SONG = 24 * BAR; // 48 s

// Footage clock. The driver waits 2 s after its first reads (the track poller needs a cycle); that dead time is cut:
// footage [SEG_A0, SEG_A1] plays first, then footage jumps to SEG_B0. Nothing is retimed; the jump is on a static frame.
export const SEG_A0 = 1.15;
export const SEG_A1 = 1.75;
export const SEG_B0 = 3.45;
export const vOfFootage = (f: number) => (f <= SEG_A1 ? f - SEG_A0 : SEG_A1 - SEG_A0 + (f - SEG_B0));
export const footageOfV = (v: number) => (v <= SEG_A1 - SEG_A0 ? SEG_A0 + v : SEG_B0 + (v - (SEG_A1 - SEG_A0)));

// Scenes, in song time t (video time v = t + P, where P is the pre-roll before the first note, from session.json).
export const scenes = {
  entrances: [
    { name: "Pad", t: 0, title: "The pad comes in", track: 1 },
    { name: "Keys", t: bar(3), title: "Then the keys", track: 0 },
    { name: "Bass", t: bar(5), title: "The bass", track: 2 },
    { name: "Drums", t: bar(7), title: "The drums", track: 3 },
    { name: "Lead", t: bar(9), title: "And the hook", track: 4 },
  ],
  mix: { from: bar(11), to: bar(17) },
  verify: { from: bar(17), to: bar(19) + 1 },
  speed: { from: bar(19) + 1, to: bar(22) },
  close: { from: bar(22), to: SONG },
};

// 26-second social cut / GIF: [song time range] segments, cut on bar lines. `at` is the social-clock start.
export const social = {
  // pre-roll (hook + visible tempo/pan writes), the drums and the hook entering with their faders on screen, the end card
  segments: [
    { kind: "pre" as const, len: 0 }, // len filled from P at render time
    { kind: "song" as const, from: bar(7) - 0.5, len: 14.5 },
    { kind: "song" as const, from: bar(22), len: 6 },
  ],
};

// Sound-design hits in video seconds are built in export-cues.mjs from these song-time cues plus the real write times.
export const sfxSong: Array<[number, "whoosh" | "ding" | "boom" | "riser"]> = [
  [bar(7) - 0.0, "whoosh"],
  [bar(11), "whoosh"],
  [bar(17), "whoosh"],
  [bar(19) + 1, "whoosh"],
  [bar(22) - 0.05, "boom"],
];
