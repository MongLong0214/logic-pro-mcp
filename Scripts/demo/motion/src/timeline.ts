// The film's structure, derived from the take. No value imports, so scripts/export-cues.mjs can load it with plain node.
//
// One clock only: the film plays the take at 1.0x from F0 (just before the first request is typed) to the end of the
// session, with nothing cut or retimed. The cards are laid over the live footage (the proof card) or come after the
// session has stopped (the end card).
import type { Ev, Session } from "./types";

export const HEAD = 2.2; // the headline (frame 0, poster) is fully up for 1.8 s, then wipes away over 0.4 s
export const PROOF = 3.0; // the proof card, laid over the take while the full mix plays, before "stop" is typed
export const END = 4.5; // the end card, after the session

export type Mode = { from: number; to: number; kind: "type" | "act" };
export type Plan = {
  F0: number; // take seconds at film tau 0
  total: number; // film length
  sessionEnd: number; // tau after which footage holds still
  musicTau: number | null;
  proof: { from: number; to: number } | null;
  end: { from: number; to: number };
  modes: Mode[];
  steps: Array<Ev & { tau: number; tauEnd: number; n: number }>;
  social: Array<{ s0: number; len: number; tau0: number }>;
};

export function plan(session: Session): Plan {
  const f = session.film;
  const ps = f.prompts;
  const F0 = ps[0].t_start - HEAD;
  const tau = (t: number) => t - F0;
  const stopEnd = f.stopAt ?? ps[ps.length - 1].t_idle;
  const sessionEnd = tau(stopEnd) + 0.9;
  const last = ps[ps.length - 1];
  const proofTo = tau(last.t_start) - 0.25;
  const proof = proofTo - PROOF > tau(ps[ps.length - 2]?.t_idle ?? 0) - 0.6 ? { from: proofTo - PROOF, to: proofTo } : null;
  const end = { from: sessionEnd, to: sessionEnd + END };
  const modes: Mode[] = [];
  let cursor = 0;
  for (const [i, p] of ps.entries()) {
    const a = i === 0 ? 0 : Math.max(cursor, tau(p.t_start) - 0.35); // the film opens on the client, about to type
    if (a > cursor) modes.push({ from: cursor, to: a, kind: "act" });
    const b = tau(p.t_enter) + 0.45;
    modes.push({ from: a, to: b, kind: "type" });
    cursor = b;
  }
  modes.push({ from: cursor, to: end.to, kind: "act" });
  let n = 0;
  const steps = f.events
    .filter((e) => e.kind === "tool" || e.target === "tracks")
    .map((e) => ({ ...e, tau: tau(e.t), tauEnd: tau(e.t_end), n: ++n }));
  // social / vertical cut: the headline and first request, then from the "play" request through the drop, then the end card
  const play = ps.findIndex((p) => /play/i.test(p.text));
  const drop = ps.findIndex((p) => /drum/i.test(p.text));
  const social: Plan["social"] = [];
  let s = 0;
  const seg = (a: number, b: number) => { social.push({ s0: s, len: b - a, tau0: a }); s += b - a; };
  if (play > 0 && drop >= play) {
    seg(0, tau(ps[play].t_start) - 0.35);
    // second segment ends one bar after the drop request went idle, on a bar line of the song
    const mt = f.musicStart != null ? tau(f.musicStart) : tau(ps[play].t_enter);
    const want = tau(ps[drop].t_idle) + 2.0;
    const barEnd = mt + Math.ceil((want - mt) / 2.0) * 2.0;
    seg(tau(ps[play].t_start) - 0.35, barEnd);
  } else {
    seg(0, sessionEnd);
  }
  seg(end.from - 0.15, end.to);
  return { F0, total: end.to, sessionEnd, musicTau: f.musicStart != null ? tau(f.musicStart) : null, proof, end, modes, steps, social };
}

export const modeAt = (p: Plan, t: number) => p.modes.find((m) => t >= m.from && t < m.to) ?? p.modes[p.modes.length - 1];
