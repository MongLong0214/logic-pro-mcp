import React, { createContext, useContext } from "react";
import { AbsoluteFill, Img, useCurrentFrame, useVideoConfig } from "remotion";
import { CameraMotionBlur } from "@remotion/motion-blur";
import { C, MONO, SANS } from "./theme";
import { inOutCubic, linear, outExpo, prog } from "./ease";
import { HEAD, modeAt, plan, type Plan } from "./timeline";
import { LOGIC, rowTarget, type Target } from "./layout";
import type { Session } from "./types";

export const MOTION_BLUR = process.env.REMOTION_MOTION_BLUR === "1";
const FOOTAGE_BASE = process.env.REMOTION_FOOTAGE_BASE ?? "http://127.0.0.1:8765";

// ------------------------------------------------------------------ film clock
// Every element is a pure function of tau, the film's clock in seconds. The social and vertical cuts only change how
// composition time maps to tau, so every cut shows identical scenes and they can never disagree.
export type TimeMap = Array<{ s0: number; len: number; tau0: number }>;
const Tau = createContext<number>(0);
export const useTau = () => useContext(Tau);
export const WithTau: React.FC<{ map: TimeMap; children: React.ReactNode }> = ({ map, children }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = frame / fps;
  const seg = [...map].reverse().find((m) => s >= m.s0) ?? map[0];
  return <Tau.Provider value={seg.tau0 + (s - seg.s0)}>{children}</Tau.Provider>;
};

type Film = { session: Session; p: Plan };
const Ctx = createContext<Film | null>(null);
export const useFilm = () => useContext(Ctx)!;
export const FilmProvider: React.FC<{ session: Session; children: React.ReactNode }> = ({ session, children }) => (
  <Ctx.Provider value={{ session, p: plan(session) }}>{children}</Ctx.Provider>
);

const useVertical = () => {
  const { width, height } = useVideoConfig();
  return height > width;
};

// ------------------------------------------------------------------ footage (JPEG sequences, never a <video>)
// Take frames are 60 fps from the first Logic frame; client frames are 30 fps from the first client frame. Indices are
// clamped to the frames that exist, so a request past either end shows the nearest real frame, never a blank one.
const takeUrl = (s: Session, t: number) => {
  const tk = s.film.take;
  const n = Math.max(0, Math.min((tk.frames ?? 1) - 1, Math.round(t * 60)));
  return `${FOOTAGE_BASE}/${tk.seq}/${String(n + 1).padStart(5, "0")}.jpg`;
};
const clientUrl = (s: Session, t: number) => {
  const c = s.film.client;
  const n = Math.max(0, Math.min((c.frames ?? 1) - 1, Math.round((t - c.offset) * 30)));
  return `${FOOTAGE_BASE}/${c.seq}/${String(n + 1).padStart(5, "0")}.jpg`;
};

// take seconds shown at film time tau: 1.0x everywhere, held still after the session
export const takeTime = (p: Plan, tau: number) => p.F0 + Math.min(tau, p.sessionEnd);

// ------------------------------------------------------------------ virtual camera on the Logic capture
type Key = { at: number; dur: number; to: Target };
const lerpT = (a: Target, b: Target, k: number): Target => ({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, z: a.z + (b.z - a.z) * k });
const MEDIUM: Target = { x: 0.3, y: 0.27, z: 1.45 };

const targetOf = (call: string, track: number | null | undefined, readTarget?: string): Target => {
  if (call.endsWith("set_tempo")) return LOGIC.lcd;
  if (call.endsWith(".play") || call.endsWith(".stop")) return LOGIC.transport;
  if ((call.endsWith("set_volume") || call.endsWith("set_pan")) && typeof track === "number") return rowTarget(track);
  if (readTarget === "tracks" || readTarget === "session") return LOGIC.tracks;
  if (readTarget === "transport/state") return LOGIC.lcd;
  return MEDIUM;
};

const cameraKeys = (p: Plan): Key[] => {
  const keys: Key[] = [{ at: -10, dur: 0, to: MEDIUM }];
  for (const m of p.modes) {
    if (m.kind === "type") { keys.push({ at: m.from, dur: 0.7, to: MEDIUM }); continue; }
    const inside = p.steps.filter((s) => s.tau >= m.from - 0.2 && s.tau < m.to);
    inside.forEach((s, i) => {
      // first write of a turn: hard cut to its close-up; later writes in the same turn: a quick whip-pan
      keys.push({ at: Math.max(m.from, s.tau - 0.12), dur: i === 0 ? 0 : 0.32, to: targetOf(s.call, s.track, s.target) });
    });
  }
  return keys.sort((a, b) => a.at - b.at);
};

const camAt = (keys: Key[], tau: number): Target => {
  let cur = keys[0].to;
  for (let i = 1; i < keys.length; i++) {
    const k = keys[i];
    if (tau < k.at) break;
    const from = cur;
    cur = k.dur <= 0 || tau >= k.at + k.dur ? k.to : lerpT(from, k.to, inOutCubic((tau - k.at) / k.dur));
  }
  return cur;
};

const LogicView: React.FC<{ w: number; h: number; cam: Target; t: number; highlight: { row: number; a: number } | null }> = ({ w, h, cam, t, highlight }) => {
  const { session } = useFilm();
  const tk = session.film.take;
  const cover = Math.max(w / tk.width, h / tk.height);
  const sc = cover * cam.z;
  const fw = tk.width * sc, fh = tk.height * sc;
  let tx = w / 2 - cam.x * fw, ty = h / 2 - cam.y * fh;
  tx = Math.min(0, Math.max(w - fw, tx));
  ty = Math.min(0, Math.max(h - fh, ty));
  const inner = (
    <div style={{ position: "absolute", left: tx, top: ty, width: fw, height: fh }}>
      <Img src={takeUrl(session, t)} style={{ width: fw, height: fh, display: "block" }} />
      {highlight && highlight.a > 0.01 && (
        <div style={{ position: "absolute", left: fw * 0.004, width: fw * LOGIC.rowW, top: fh * (LOGIC.rowY[highlight.row] - 0.028), height: fh * 0.056,
          border: `${Math.max(2, 4 * sc / cover / 3)}px solid ${C.acid}`, borderRadius: 10, opacity: highlight.a, boxShadow: `0 0 24px ${C.acid}88` }} />
      )}
    </div>
  );
  return <div style={{ position: "absolute", inset: 0, overflow: "hidden", background: C.deep }}>{MOTION_BLUR ? <CameraMotionBlur samples={5} shutterAngle={120}>{inner}</CameraMotionBlur> : inner}</div>;
};

const ClientView: React.FC<{ w: number; h: number; t: number }> = ({ w, h, t }) => {
  const { session } = useFilm();
  const c = session.film.client;
  const sc = Math.min(w / c.width, h / c.height);
  const fw = c.width * sc, fh = c.height * sc;
  return (
    <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <Img src={clientUrl(session, t)} style={{ width: fw, height: fh, display: "block", borderRadius: 14, boxShadow: "0 30px 80px rgba(0,0,0,0.55)" }} />
    </div>
  );
};

// ------------------------------------------------------------------ type
export const Words: React.FC<{ text: string; at: number; size: number; color?: string; accent?: string[]; align?: "left" | "center"; weight?: number; gap?: number }> = ({ text, at, size, color = C.paper, accent = [], align = "left", weight = 600, gap = 0.06 }) => {
  const tau = useTau();
  let i = 0;
  return (
    <div style={{ fontFamily: SANS, fontSize: size, fontWeight: weight, color, lineHeight: 1.0, letterSpacing: "-0.045em", textAlign: align }}>
      {text.split("\n").map((line, li) => (
        <div key={li} style={{ display: "flex", flexWrap: "wrap", justifyContent: align === "center" ? "center" : "flex-start", gap: `0 ${size * 0.26}px` }}>
          {line.split(" ").map((w) => {
            const p = prog(tau, at + gap * i++, at + gap * (i - 1) + 0.4, outExpo);
            return (
              <span key={w + i} style={{ display: "inline-block", overflow: "hidden", paddingBottom: size * 0.14, marginBottom: -size * 0.14 }}>
                <span style={{ display: "inline-block", transform: `translateY(${(1 - p) * 105}%)`, color: accent.includes(w.replace(/[.,]/g, "")) ? C.acid : color }}>{w}</span>
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

export const Mono: React.FC<{ children: React.ReactNode; size: number; color?: string; style?: React.CSSProperties }> = ({ children, size, color = C.sage, style }) => (
  <div style={{ fontFamily: MONO, fontSize: size, color, letterSpacing: "0.01em", ...style }}>{children}</div>
);

export const Bars: React.FC<{ size: number; t: number }> = ({ size, t }) => (
  <div style={{ display: "flex", gap: size * 0.12, alignItems: "flex-end", height: size, width: size * 0.84 }}>
    {[0.42, 1, 0.68].map((b, i) => <div key={i} style={{ flex: 1, height: `${(b * 0.72 + (0.5 + 0.5 * Math.sin(t * 5.2 + i * 1.9)) * 0.28 * b) * 100}%`, background: C.acid, borderRadius: size * 0.05 }} />)}
  </div>
);

export const Logo: React.FC<{ size: number; t: number }> = ({ size, t }) => (
  <div style={{ display: "flex", alignItems: "center", gap: size * 0.32 }}>
    <div style={{ width: size * 1.35, height: size * 1.35, borderRadius: size * 0.34, background: C.deep, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: `0 0 0 ${size * 0.03}px ${C.line}` }}>
      <Bars size={size * 0.74} t={t} />
    </div>
    <div style={{ fontFamily: SANS, fontSize: size, fontWeight: 600, letterSpacing: "-0.05em", color: C.paper }}>Logic Pro <span style={{ color: C.acid }}>MCP</span></div>
  </div>
);

// ------------------------------------------------------------------ captions
const shortCall = (call: string) => call.replace(/^logic_/, "");

/** One chip per write, in order: what changed, before → after, and what the server answered. Sizes for 1920 wide. */
const StepChip: React.FC<{ s: Plan["steps"][number]; a: number; scale: number }> = ({ s, a, scale }) => {
  const isRead = s.kind === "read";
  const READS: Record<string, string> = { tracks: "Reads the tracks back", "transport/state": "Reads the transport", session: "Reads the session" };
  const title = isRead ? READS[s.target ?? ""] ?? "Reads Logic" : s.noop ? `${s.what} (no change)` : s.what;
  return (
    <div style={{ opacity: a, transform: `translateY(${(1 - a) * 24}px)`, background: "rgba(16,21,18,0.95)", borderLeft: `${8 * scale}px solid ${C.acid}`,
      borderRadius: 16 * scale, padding: `${14 * scale}px ${26 * scale}px ${16 * scale}px`, marginTop: 12 * scale, boxShadow: "0 18px 40px rgba(0,0,0,0.45)" }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 18 * scale, whiteSpace: "nowrap" }}>
        <Mono size={30 * scale} color={C.acid}>{String(s.n).padStart(2, "0")}</Mono>
        <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 54 * scale, letterSpacing: "-0.04em", color: C.paper, lineHeight: 1.05 }}>{title}</div>
        {!isRead && s.before_after && <Mono size={50 * scale} color={C.acid} style={{ fontWeight: 600, whiteSpace: "nowrap" }}>{s.before_after}</Mono>}
      </div>
      <Mono size={28 * scale} color={C.sage} style={{ marginTop: 4 * scale, whiteSpace: "nowrap" }}>
        {isRead ? `${s.summary ?? s.target} · ${Math.round(s.ms)} ms` : `${shortCall(s.call)} · ${s.result ?? ""} · ${Math.round(s.ms)} ms`}
      </Mono>
    </div>
  );
};

const Steps: React.FC<{ scale: number }> = ({ scale }) => {
  const tau = useTau();
  const { p } = useFilm();
  const live = p.steps
    .map((s) => {
      const hold = Math.max(s.tauEnd + 1.3, s.tau + 1.8);
      return { s, a: prog(tau, s.tau, s.tau + 0.25) * (1 - prog(tau, hold, hold + 0.3)) };
    })
    .filter((x) => x.a > 0.01)
    .slice(-2);
  return <>{live.map(({ s, a }) => <StepChip key={s.n} s={s} a={a} scale={scale} />)}</>;
};

/** The request being typed, large, in step with the real keystrokes in the client window beside it. */
const PromptLine: React.FC<{ size: number; maxWidth: number }> = ({ size, maxWidth }) => {
  const tau = useTau();
  const { session, p } = useFilm();
  const pr = [...session.film.prompts].reverse().find((x) => x.t_start - p.F0 - 0.2 <= tau);
  if (!pr) return null;
  const a0 = pr.t_start - p.F0, a1 = pr.t_enter - p.F0 - 0.25, z = pr.t_idle - p.F0;
  const a = prog(tau, a0 - 0.2, a0 + 0.1) * (1 - prog(tau, z + 0.2, z + 0.6));
  if (a <= 0.01) return null;
  const n = Math.round(pr.text.length * Math.min(1, Math.max(0, (tau - a0) / Math.max(0.1, a1 - a0))));
  const sent = tau >= pr.t_enter - p.F0;
  return (
    <div style={{ opacity: a, maxWidth }}>
      <Mono size={size * 0.46} color={C.acid}>{sent ? "YOU ASKED CLAUDE" : "YOU TYPE"}</Mono>
      <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: size, letterSpacing: "-0.035em", color: C.paper, lineHeight: 1.08, marginTop: size * 0.12 }}>
        “{pr.text.slice(0, n)}{!sent && <span style={{ color: C.acid }}>▍</span>}{sent ? "”" : ""}
      </div>
    </div>
  );
};

// ------------------------------------------------------------------ layout blend between "typing" and "acting"
const modeBlend = (p: Plan, tau: number) => {
  // 0 = the client is the hero (a request is being typed), 1 = Logic is the hero (Claude is calling tools)
  const m = modeAt(p, tau);
  const target = m.kind === "act" ? 1 : 0;
  const idx = p.modes.indexOf(m);
  const prev = idx > 0 ? (p.modes[idx - 1].kind === "act" ? 1 : 0) : target;
  const k = inOutCubic(Math.min(1, Math.max(0, (tau - m.from) / 0.45)));
  return prev + (target - prev) * k;
};

// ------------------------------------------------------------------ the film
export const LaunchFilm: React.FC = () => {
  const tau = useTau();
  const { session, p } = useFilm();
  const { width: W, height: H } = useVideoConfig();
  const vertical = useVertical();
  const t = takeTime(p, tau);
  const keys = React.useMemo(() => cameraKeys(p), [p]);
  const m = modeBlend(p, tau);
  let cam = camAt(keys, tau);
  // a slow push-in while a close-up holds, so no shot is ever dead still
  const lastKey = [...keys].reverse().find((k) => k.at <= tau);
  if (lastKey && lastKey.to !== MEDIUM) cam = { ...cam, z: cam.z * (1 + 0.035 * Math.min(1, (tau - lastKey.at) / 2.5)) };

  // highlight the row whose control is being written
  let hl: { row: number; a: number } | null = null;
  for (const s of p.steps) {
    if (typeof s.track !== "number" || s.kind !== "tool") continue;
    const a = prog(tau, s.tau - 0.12, s.tau + 0.05, linear) * (1 - prog(tau, s.tauEnd + 0.4, s.tauEnd + 0.8, linear));
    if (a > 0.01 && (!hl || a > hl.a)) hl = { row: s.track, a };
  }

  // panels
  const pad = vertical ? 40 : 56;
  let client: { x: number; y: number; w: number; h: number }, logic: { x: number; y: number; w: number; h: number };
  if (!vertical) {
    const top = 210, bottom = 92;
    const cw = 880 - 140 * m; // the client panel narrows from 880 px (typing) to 740 px (Claude acting in Logic)
    client = { x: pad, y: top, w: cw, h: H - top - bottom };
    logic = { x: pad + cw + 28, y: top, w: W - (pad + cw + 28) - pad, h: H - top - bottom };
  } else {
    const top = 300;
    const ch = 700 - 230 * m;
    client = { x: pad, y: top, w: W - 2 * pad, h: ch };
    logic = { x: pad, y: top + ch + 24, w: W - 2 * pad, h: H - (top + ch + 24) - 420 };
  }

  // cards
  const headA = 1 - prog(tau, HEAD - 0.4, HEAD, inOutCubic);
  const proofA = p.proof ? prog(tau, p.proof.from, p.proof.from + 0.35) * (1 - prog(tau, p.proof.to - 0.3, p.proof.to)) : 0;
  const endA = prog(tau, p.end.from, p.end.from + 0.5, outExpo);
  const st = session.stats;

  return (
    <AbsoluteFill style={{ background: C.deep, fontFamily: SANS }}>
      {/* the two live captures */}
      <div style={{ position: "absolute", left: client.x, top: client.y, width: client.w, height: client.h }}>
        <ClientView w={client.w} h={client.h} t={t} />
      </div>
      <div style={{ position: "absolute", left: logic.x, top: logic.y, width: logic.w, height: logic.h, borderRadius: 18, overflow: "hidden", boxShadow: `0 0 0 2px ${C.line}, 0 30px 80px rgba(0,0,0,0.55)` }}>
        <LogicView w={logic.w} h={logic.h} cam={cam} t={t} highlight={hl} />
      </div>

      {/* labels over the panels */}
      <div style={{ position: "absolute", left: client.x, top: client.y - 44 }}><Mono size={28} color={C.sage}>{session.meta.client} · real session</Mono></div>
      <div style={{ position: "absolute", left: logic.x, top: logic.y - 44 }}><Mono size={28} color={C.sage}>Logic Pro {session.meta.logic.split(" ")[0]} · live</Mono></div>

      {/* the request, large */}
      <div style={{ position: "absolute", left: pad, top: vertical ? 56 : 40, right: pad }}>
        <PromptLine size={vertical ? 62 : 58} maxWidth={vertical ? W - 2 * pad : 1800} />
      </div>

      {/* write chips */}
      <div style={{ position: "absolute", left: vertical ? pad : logic.x + 24, right: vertical ? pad : undefined, bottom: vertical ? 120 : 92 + 24, maxWidth: vertical ? undefined : logic.w - 48 }}>
        <Steps scale={vertical ? 0.92 : 0.86} />
      </div>

      <div style={{ position: "absolute", left: pad, bottom: vertical ? 40 : 30, fontFamily: MONO, fontSize: 28, color: C.paper, opacity: 0.85 }}>
        Real {session.meta.client} session{session.meta.model ? ` (${session.meta.model})` : ""} · live Logic Pro · 1.0x, one continuous take
      </div>

      {/* headline: frame 0 is this finished frame (it is the poster and the thumbnail) */}
      {headA > 0.001 && (
        <AbsoluteFill style={{ background: `rgba(16,21,18,${0.9 * headA})`, clipPath: `inset(0 0 ${(1 - headA) * 100}% 0)` }}>
          <div style={{ position: "absolute", left: vertical ? 64 : 110, top: vertical ? 300 : 150 }}>
            <Logo size={vertical ? 64 : 58} t={tau} />
            <div style={{ marginTop: vertical ? 90 : 70 }}>
              <Words text={vertical ? "Ask Claude.\nLogic Pro\ndoes it." : "Ask Claude.\nLogic Pro does it."} at={-3} size={vertical ? 150 : 168} accent={["Claude"]} />
            </div>
            <Mono size={vertical ? 36 : 40} color={C.acid} style={{ marginTop: 44 }}>Real Claude Code session · live Logic Pro 13 · real time</Mono>
          </div>
        </AbsoluteFill>
      )}

      {/* proof: over the live take while the full mix plays */}
      {proofA > 0.001 && (
        <AbsoluteFill style={{ background: `rgba(16,21,18,${0.86 * proofA})`, opacity: Math.min(1, proofA * 1.4) }}>
          <div style={{ position: "absolute", left: vertical ? 64 : 110, top: vertical ? 420 : 170, right: vertical ? 64 : 110, transform: `scale(${0.96 + 0.04 * proofA})`, transformOrigin: "left top" }}>
            <Mono size={36} color={C.acid}>WHAT LOGIC ANSWERED</Mono>
            <div style={{ marginTop: 26 }}><Words text={vertical ? "Every write\nwas read back." : "Every write was read back."} at={(p.proof?.from ?? 0) + 0.05} size={vertical ? 110 : 120} accent={["back."]} /></div>
            <div style={{ display: "flex", flexDirection: vertical ? "column" : "row", gap: vertical ? 30 : 80, marginTop: 70, alignItems: vertical ? "flex-start" : "flex-end" }}>
              <div>
                <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 200, color: C.acid, letterSpacing: "-0.06em", lineHeight: 0.9, whiteSpace: "nowrap" }}>{st.medianMs}<span style={{ fontSize: 80, color: C.paper, letterSpacing: "-0.02em", marginLeft: 18 }}>ms</span></div>
                <Mono size={38} color={C.paper} style={{ marginTop: 12, whiteSpace: "nowrap" }}>median round trip, {st.realWrites} real writes</Mono>
              </div>
              <div style={{ paddingBottom: 8, whiteSpace: "nowrap" }}>
                <Mono size={38} color={C.paper}>{st.verifiedRealWrites} of {st.realWrites} verified by read-back (State A)</Mono>
                <Mono size={38} color={C.sage} style={{ marginTop: 8 }}>{st.calls} MCP calls shown, every one logged</Mono>
              </div>
            </div>
          </div>
        </AbsoluteFill>
      )}

      {/* end card: slides up over the stopped session */}
      {endA > 0.001 && (() => {
        const lt = tau - p.end.from;
        return (
          <AbsoluteFill style={{ background: C.deep, transform: `translateY(${(1 - endA) * 100}%)`, alignItems: "center" }}>
            <div style={{ position: "absolute", top: vertical ? 260 : 96 }}><Logo size={vertical ? 72 : 76} t={tau} /></div>
            <div style={{ position: "absolute", top: vertical ? 470 : 250, width: vertical ? 960 : 1720 }}>
              <Words text={vertical ? "Drive Logic Pro\nfrom Claude or\nany MCP client." : "Drive Logic Pro from Claude\nor any MCP client."} at={p.end.from + 0.15} size={vertical ? 92 : 96} align="center" accent={["Claude", "MCP"]} />
            </div>
            <div style={{ position: "absolute", top: vertical ? 900 : 520, display: "grid", gap: 16, justifyItems: "center", opacity: prog(lt, 0.5, 0.9), padding: "0 40px" }}>
              {["brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp", "brew install logic-pro-mcp"].map((c) => (
                <div key={c} style={{ fontFamily: MONO, fontSize: vertical ? 30 : 36, background: C.ink, color: C.paper, border: `2px solid ${C.line}`, padding: "14px 30px", borderRadius: 16, maxWidth: vertical ? 1000 : 1760, textAlign: "center", wordBreak: "break-word" }}>
                  <span style={{ color: C.sage }}>$ </span>{c}
                </div>
              ))}
            </div>
            <div style={{ position: "absolute", top: vertical ? 1260 : 790, display: "flex", flexDirection: vertical ? "column" : "row", gap: 28, alignItems: "center", opacity: prog(lt, 1.0, 1.4) }}>
              <div style={{ background: C.acid, color: C.ink, fontFamily: SANS, fontWeight: 600, fontSize: 52, padding: "18px 50px", borderRadius: 999 }}>★  Star on GitHub</div>
              <Mono size={vertical ? 34 : 40} color={C.paper}>github.com/MongLong0214/logic-pro-mcp</Mono>
            </div>
            <div style={{ position: "absolute", bottom: vertical ? 300 : 120, opacity: prog(lt, 1.3, 1.7) }}><Mono size={46} color={C.acid}>logicpromcp.com</Mono></div>
            <div style={{ position: "absolute", bottom: vertical ? 80 : 40, left: 60, right: 60, textAlign: "center", opacity: prog(lt, 1.5, 1.9) }}>
              <Mono size={vertical ? 26 : 28} color={C.sage}>v{session.meta.version} · Logic Pro {session.meta.logic} · macOS {session.meta.macos} · {session.meta.locale} · song and tracks prepared in advance; every change shown is a live MCP call Claude made</Mono>
            </div>
          </AbsoluteFill>
        );
      })()}
    </AbsoluteFill>
  );
};
