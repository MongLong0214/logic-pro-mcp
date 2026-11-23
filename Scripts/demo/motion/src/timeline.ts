// The film's structure, derived from the take. No value imports, so scripts/export-cues.mjs can load it with plain node.
//
// One clock only: the film plays the take at 1.0x from F0 (just before the first request is typed) to the end of the
// session, with nothing cut or retimed. The cards are laid over the live footage (the proof card) or come after the
// session has stopped (the end card).
import type { Ev, Session } from "./types";

export const HEAD = 2.2; // the headline (frame 0, poster) is fully up for 1.8 s, then wipes away over 0.4 s
export const READ_HOLD = 3.4; // Claude's last answer stays on screen this long after the turn goes idle (it is on screen by then)
export const PROOF = 3.0; // the proof card, over the live take, after the read-back: every count on it has already happened
export const END = 8.5; // the end card: its last element is in at about 2.4 s, so the complete card is held for more than 6 s
export const PROMPT_HOLD = 2.3; // a finished request stays up this long after its turn goes idle

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
  const readEnd = tau(stopEnd) + READ_HOLD;
  const proof = { from: readEnd, to: readEnd + PROOF }; // after the last answer: all calls have happened by now
  const sessionEnd = proof.to; // the footage runs live to here and is held still under the end card
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
    .filter((e) => e.kind === "tool" || ["tracks", "transport/state", "session", "mixer"].includes(e.target ?? ""))
    .map((e) => ({ ...e, tau: tau(e.t), tauEnd: tau(e.t_end), n: ++n }));
  // social / vertical cut: the headline, then from the "play" request through the Lead's entrance (to a bar line, with the
  // finished request still up), then the end card. The middle segment is one unbroken stretch of the take at 1.0x.
  const play = ps.findIndex((p) => /play/i.test(p.text));
  const drop = ps.findIndex((p, i) => i > play && /drum/i.test(p.text)); // the drums entrance, after playback started
  const lead = ps.findIndex((p, i) => i > drop && /lead/i.test(p.text)); // the last part to come in
  const social: Plan["social"] = [];
  let s = 0;
  const seg = (a: number, b: number) => { social.push({ s0: s, len: b - a, tau0: a }); s += b - a; };
  if (play > 0 && drop >= play) {
    seg(0, HEAD + 0.3); // the headline, then a cut straight to the request that starts playback
    const last = lead > drop ? lead : drop;
    const mt = f.musicStart != null ? tau(f.musicStart) : tau(ps[play].t_enter);
    const want = tau(ps[last].t_idle) + 1.0; // one beat of the finished request, then the next bar line
    const barEnd = mt + Math.ceil((want - mt) / 2.0) * 2.0;
    seg(tau(ps[play].t_start) - 0.35, barEnd);
  } else {
    seg(0, sessionEnd);
  }
  seg(end.from - 0.15, end.to);
  return { F0, total: end.to, sessionEnd, musicTau: f.musicStart != null ? tau(f.musicStart) : null, proof, end, modes, steps, social };
}

export const modeAt = (p: Plan, t: number) => p.modes.find((m) => t >= m.from && t < m.to) ?? p.modes[p.modes.length - 1];
