import React, { createContext, useContext } from "react";
import { AbsoluteFill, Img, useCurrentFrame, useVideoConfig } from "remotion";
import { CameraMotionBlur } from "@remotion/motion-blur";
import { C, MONO, SANS } from "./theme";
import { inOutCubic, linear, outExpo, prog, track } from "./ease";
import { BAR, SONG, bar, footageOfV, scenes, vOfFootage } from "./timeline";
import type { Ev, Session } from "./types";

export const MOTION_BLUR = process.env.REMOTION_MOTION_BLUR === "1";
const FOOTAGE_BASE = process.env.REMOTION_FOOTAGE_BASE ?? "http://127.0.0.1:8765";

// ------------------------------------------------------------------ film clock
// Every element is a pure function of tau, the film's own clock in seconds. The social cut only changes how
// composition time maps to tau, so both cuts show identical scenes and can never disagree.
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

type Film = { session: Session; P: number };
const Ctx = createContext<Film | null>(null);
export const useFilm = () => useContext(Ctx)!;
export const FilmProvider: React.FC<{ session: Session; children: React.ReactNode }> = ({ session, children }) => {
  const P = vOfFootage(session.film.musicStart);
  return <Ctx.Provider value={{ session, P }}>{children}</Ctx.Provider>;
};

// ------------------------------------------------------------------ footage (JPEG sequence, never a <video>)
const frameUrl = (film: Session["film"], tau: number) => {
  const n = Math.round(footageOfV(tau) * film.fps);
  return `${FOOTAGE_BASE}/${film.seq}/${String(n).padStart(5, "0")}.jpg`;
};

type Cam = { x: number; y: number; z: number };
// Normalised footage coordinates of the five track rows (arrange view, Inspector hidden)
const ROW_Y = [0.189, 0.25, 0.312, 0.374, 0.435];

export const camAt = (tau: number, P: number): Cam => {
  const follow = (t: number) => 0.4 + 0.18 * (t / SONG);
  const keys = (sel: (c: Cam) => number): Array<[number, number]> => {
    const pts: Array<[number, Cam]> = [
      [0, { x: 0.5, y: 0.5, z: 1.0 }],
      [0.8, { x: 0.5, y: 0.5, z: 1.0 }],
      [1.15, { x: 0.5, y: 0.075, z: 2.9 }], // the transport display while the tempo is written
      [1.9, { x: 0.5, y: 0.075, z: 2.9 }],
      [P + 0.1, { x: follow(0), y: 0.4, z: 1.25 }],
      [P + SONG, { x: follow(SONG), y: 0.4, z: 1.25 }],
    ];
    return pts.map(([t, c]) => [t, sel(c)]);
  };
  return { x: track(tau, keys((c) => c.x), inOutCubic), y: track(tau, keys((c) => c.y), inOutCubic), z: track(tau, keys((c) => c.z), inOutCubic) };
};

export const Footage: React.FC<{ dim: number; blur: number; highlight?: { row: number; a: number } | null }> = ({ dim, blur, highlight }) => {
  const tau = useTau();
  const { session, P } = useFilm();
  const film = session.film;
  const { width, height } = useVideoConfig();
  const aspect = film.width / film.height;
  const cam = camAt(tau, P);
  const fw = Math.max(width, height * aspect);
  const fh = fw / aspect;
  const tx = width / 2 - cam.x * fw * cam.z;
  const ty = height / 2 - cam.y * fh * cam.z;
  const inner = (
    <div style={{ position: "absolute", left: 0, top: 0, width: fw, height: fh, transformOrigin: "0 0", transform: `translate(${tx}px, ${ty}px) scale(${cam.z})`,
      filter: dim > 0.01 ? `brightness(${1 - dim})` : undefined }}>
      <Img src={frameUrl(film, tau)} style={{ width: fw, height: fh, display: "block" }} />
      {highlight && highlight.a > 0.01 && (
        <div style={{ position: "absolute", left: fw * 0.004, width: fw * 0.166, top: fh * (ROW_Y[highlight.row] - 0.029), height: fh * 0.058,
          border: `${3 / cam.z}px solid ${C.acid}`, borderRadius: 10 / cam.z, opacity: highlight.a, boxShadow: `0 0 ${24 / cam.z}px ${C.acid}88` }} />
      )}
    </div>
  );
  return <AbsoluteFill style={{ background: C.deep, overflow: "hidden" }}>{MOTION_BLUR ? <CameraMotionBlur samples={5} shutterAngle={110}>{inner}</CameraMotionBlur> : inner}</AbsoluteFill>;
};

// ------------------------------------------------------------------ type
export const Words: React.FC<{ text: string; at: number; size: number; color?: string; accent?: string[]; align?: "left" | "center"; weight?: number; gap?: number }> = ({ text, at, size, color = C.paper, accent = [], align = "left", weight = 600, gap = 0.07 }) => {
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
  <div style={{ fontFamily: MONO, fontSize: size, color, letterSpacing: "0.02em", ...style }}>{children}</div>
);

export const Bars: React.FC<{ size: number; t: number }> = ({ size, t }) => (
  <div style={{ display: "flex", gap: size * 0.12, alignItems: "flex-end", height: size, width: size * 0.84 }}>
    {[0.42, 1, 0.68].map((b, i) => <div key={i} style={{ flex: 1, height: `${(b * 0.72 + (0.5 + 0.5 * Math.sin(t * 5.2 + i * 1.9)) * 0.28 * b) * 100}%`, background: C.acid, borderRadius: size * 0.05 }} />)}
  </div>
);

export const Logo: React.FC<{ size: number; t: number }> = ({ size, t }) => (
  <div style={{ display: "flex", alignItems: "center", gap: size * 0.32 }}>
    <div style={{ width: size * 1.35, height: size * 1.35, borderRadius: size * 0.34, background: C.deep, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: `0 0 0 ${size * 0.025}px ${C.line}` }}>
      <Bars size={size * 0.74} t={t} />
    </div>
    <div style={{ fontFamily: SANS, fontSize: size, fontWeight: 600, letterSpacing: "-0.05em", color: C.paper }}>Logic Pro <span style={{ color: C.acid }}>MCP</span></div>
  </div>
);

// ------------------------------------------------------------------ captions and transcript
/** Lower third on a solid scrim so it never fights Logic's own labels. Sizes are for a 1920x1080 frame. */
export const Lower: React.FC<{ n: string; title: string; detail?: string; from: number; to: number }> = ({ n, title, detail, from, to }) => {
  const tau = useTau();
  const a = prog(tau, from, from + 0.35) * (1 - prog(tau, to - 0.25, to));
  if (a <= 0.001) return null;
  return (
    <div style={{ position: "absolute", left: 64, bottom: 112, width: 900, padding: "22px 32px 24px", background: "rgba(16,21,18,0.94)", borderLeft: `8px solid ${C.acid}`,
      borderRadius: 16, opacity: a, transform: `translateY(${(1 - a) * 28}px)` }}>
      <Mono size={36} color={C.acid}>{n}</Mono>
      <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 76, letterSpacing: "-0.045em", color: C.paper, lineHeight: 1.05 }}>{title}</div>
      {detail && <Mono size={36} color={C.paper} style={{ opacity: 0.85, marginTop: 6 }}>{detail}</Mono>}
    </div>
  );
};

const fmtArgs = (a: string) => {
  try { const o = JSON.parse(a); return Object.entries(o).map(([k, v]) => `${k} ${v}`).join(", "); } catch { return a.replace("logic://", ""); }
};

/** Real calls, real order, newest at the bottom. Three rows at 34 px; sits in the empty lower half of Logic's window. */
export const Transcript: React.FC<{ events: Ev[]; now: number }> = ({ events, now }) => {
  const shown = events.filter((e) => e.t <= now).slice(-3);
  const size = 34;
  return (
    <div style={{ position: "absolute", right: 64, bottom: 112, width: 860, background: "rgba(16,21,18,0.95)", border: `1.5px solid ${C.line}`, borderRadius: 16, overflow: "hidden", fontFamily: MONO }}>
      <div style={{ padding: "10px 22px", borderBottom: `1.5px solid ${C.line}`, color: C.sage, fontSize: 30 }}>MCP client · stdio · v3.19.0</div>
      <div style={{ padding: "14px 22px 6px", minHeight: 3 * size * 2.3 }}>
        {shown.map((e, i) => (
          <div key={`${e.t}-${i}`} style={{ marginBottom: 12, opacity: 0.55 + 0.45 * (i / Math.max(1, shown.length - 1) || 1) }}>
            <div style={{ color: C.acid, fontSize: size, whiteSpace: "nowrap" }}>▸ {e.call.replace(/^logic_\w+\./, "")} <span style={{ color: C.paper, opacity: 0.85 }}>{fmtArgs(e.args)}</span></div>
            <div style={{ color: e.ok ? C.sage : C.warn, fontSize: size, whiteSpace: "nowrap" }}>{e.ok ? "✓" : "!"} {e.result.replace("State ", "")} · {Math.round(e.ms)} ms</div>
          </div>
        ))}
      </div>
    </div>
  );
};

export const Tag: React.FC<{ label: string }> = ({ label }) => (
  <div style={{ position: "absolute", left: 64, bottom: 36, fontFamily: MONO, fontSize: 40, color: C.paper, opacity: 0.9, textShadow: "0 2px 12px rgba(0,0,0,0.9)" }}>{label}</div>
);

// ------------------------------------------------------------------ the film
const fmtRow = (name: string) => name;

export const LaunchFilm: React.FC = () => {
  const tau = useTau();
  const { session, P } = useFilm();
  const film = session.film;
  const t = tau - P; // song time
  const fNow = footageOfV(tau);
  const events = film.events;
  const writes = events.filter((e) => e.kind === "tool" && !/\.(play|stop)$/.test(e.call));
  const total = P + SONG;

  // dim and blur: the footage recedes under the cards, never goes black
  const cardA = prog(tau, P + scenes.verify.from - 0.3, P + scenes.verify.from + 0.4) ;
  const closeA = prog(tau, P + scenes.close.from - 0.3, P + scenes.close.from + 0.5);
  const hookA = 1 - prog(tau, 0.6, 0.95);
  const dim = Math.max(hookA * 0.62, cardA * 0.7, closeA * 0.55);
  const blur = 0; // CSS blur at 4K with motion-blur sampling is far too slow; the dim carries the separation

  // entrance highlight on the track whose fader is being written
  let hl: { row: number; a: number } | null = null;
  for (const e of writes) {
    const m = e.args.match(/"track":(\d)/);
    if (!m) continue;
    const a = prog(tau, vOfFootage(e.t) - 0.15, vOfFootage(e.t) + 0.05, linear) * (1 - prog(tau, vOfFootage(e.t) + e.ms / 1000 + 0.15, vOfFootage(e.t) + e.ms / 1000 + 0.55, linear));
    if (a > 0.01 && (!hl || a > hl.a)) hl = { row: Number(m[1]), a };
  }

  const showClient = tau > 0.5 && !(tau > P + scenes.verify.from - 0.3);
  const detailWrite = "mixer.set_volume · fader up · read back";
  const lowers: React.ReactNode[] = [
    <Lower key="r" n="01 — READ" title="Reads tracks and transport" from={0.95} to={1.6} />,
    <Lower key="t" n="02 — SET" title="Sets the tempo, 90 → 120" from={1.6} to={2.2} />,
    <Lower key="p" n="03 — PLACE" title="Pans every track" from={2.2} to={P + 0.5} />,
    ...scenes.entrances.map((s, i) => (
      <Lower key={s.name} n={`0${4 + i} — ENTER`.slice(-10)} title={s.title} detail={detailWrite} from={P + s.t + 0.2} to={P + s.t + 3.9} />
    )),
    <Lower key="m" n="09 — MIX" title="Mixes on command" detail="mixer.set_pan · mixer.set_volume · live" from={P + scenes.mix.from + 0.2} to={P + scenes.mix.to - 0.2} />,
  ];

  const lastWrite = [...writes].reverse().find((e) => e.label.startsWith("ride: Lead")) ?? writes[writes.length - 1];

  return (
    <AbsoluteFill style={{ background: C.deep }}>
      <Footage dim={dim} blur={blur} highlight={hl} />
      {/* hook: the finished headline is on screen at frame 0 */}
      {tau < 1.0 && (
        <div style={{ position: "absolute", left: 72, top: 120, opacity: 1 - prog(tau, 0.6, 0.95, linear) }}>
          <Words text={"Drive Logic Pro\nfrom an AI client."} at={-2} size={150} accent={["AI"]} />
          <Mono size={40} color={C.acid} style={{ marginTop: 28 }}>Scripted MCP client · live Logic Pro 13.0</Mono>
        </div>
      )}
      {showClient && tau > 0.95 && <Transcript events={events} now={fNow} />}
      {lowers}
      {showClient && tau > 0.95 && <Tag label="Scripted MCP client · live Logic Pro 13.0 · real time" />}

      {/* verify */}
      {tau > P + scenes.verify.from - 0.4 && tau < P + scenes.speed.from + 0.2 && (() => {
        const a = prog(tau, P + scenes.verify.from, P + scenes.verify.from + 0.5) * (1 - prog(tau, P + scenes.speed.from - 0.3, P + scenes.speed.from + 0.1));
        const p2 = prog(tau, P + scenes.verify.from + 1.4, P + scenes.verify.from + 2.0);
        return (
          <AbsoluteFill style={{ opacity: a, padding: "110px 96px" }}>
            <Mono size={40} color={C.acid}>10 — VERIFY</Mono>
            <Words text={"Every change shown\nis read back."} at={P + scenes.verify.from + 0.1} size={130} accent={["back."]} />
            <div style={{ position: "absolute", left: 96, right: 96, bottom: 100, display: "flex", gap: 36 }}>
              <div style={{ flex: 1, background: C.panel, border: `2px solid ${C.line}`, borderRadius: 22, padding: 30 }}>
                <Mono size={34} color={C.sage}>YOU ASK</Mono>
                <Mono size={40} color={C.paper} style={{ marginTop: 10 }}>{lastWrite.call.replace("logic_", "")}</Mono>
                <Mono size={40} color={C.acid}>{lastWrite.args}</Mono>
              </div>
              <div style={{ flex: 1, background: C.panel, border: `2px solid ${C.acid}`, borderRadius: 22, padding: 30, opacity: p2, transform: `translateY(${(1 - p2) * 24}px)` }}>
                <Mono size={34} color={C.acid}>LOGIC ANSWERS</Mono>
                <Mono size={40} color={C.paper} style={{ marginTop: 10 }}>{lastWrite.result}</Mono>
                <Mono size={40} color={C.sage}>measured {Math.round(lastWrite.ms)} ms</Mono>
              </div>
            </div>
          </AbsoluteFill>
        );
      })()}

      {/* speed */}
      {tau > P + scenes.speed.from - 0.2 && tau < P + scenes.close.from + 0.2 && (() => {
        const a = prog(tau, P + scenes.speed.from, P + scenes.speed.from + 0.4) * (1 - prog(tau, P + scenes.close.from - 0.3, P + scenes.close.from + 0.1));
        const st = session.stats;
        return (
          <AbsoluteFill style={{ opacity: a, padding: "110px 96px" }}>
            <Mono size={40} color={C.acid}>11 — SPEED</Mono>
            <Words text={"Real timings.\nNothing sped up."} at={P + scenes.speed.from + 0.1} size={130} accent={["Nothing"]} />
            <div style={{ position: "absolute", left: 96, right: 96, bottom: 100, display: "flex", gap: 60, alignItems: "flex-end" }}>
              <div>
                <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 240, color: C.acid, letterSpacing: "-0.07em", lineHeight: 0.9 }}>{st.medianMs}<span style={{ fontSize: 90, color: C.paper }}> ms</span></div>
                <Mono size={40} color={C.paper} style={{ marginTop: 14 }}>median of {st.writes} writes</Mono>
              </div>
              <div style={{ paddingBottom: 6 }}>
                <Mono size={40} color={C.paper}>{st.verifiedWrites} of {st.writes} readback-verified (State A)</Mono>
                <Mono size={40} color={C.sage}>slowest {st.maxMs} ms · all calls logged</Mono>
              </div>
            </div>
          </AbsoluteFill>
        );
      })()}

      {/* close */}
      {tau > P + scenes.close.from - 0.3 && (() => {
        const a = prog(tau, P + scenes.close.from, P + scenes.close.from + 0.5);
        const lt = tau - (P + scenes.close.from);
        return (
          <AbsoluteFill style={{ opacity: a, alignItems: "center", justifyContent: "center" }}>
            <div style={{ position: "absolute", top: 90 }}><Logo size={80} t={tau} /></div>
            <div style={{ position: "absolute", top: 260, width: 1700 }}>
              <Words text="Drive Logic Pro from any MCP client." at={P + scenes.close.from + 0.2} size={96} align="center" accent={["MCP"]} weight={600} />
            </div>
            <div style={{ position: "absolute", top: 470, display: "grid", gap: 18, justifyItems: "center", opacity: prog(lt, 0.7, 1.1) }}>
              {["brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp", "brew install logic-pro-mcp"].map((c) => (
                <div key={c} style={{ fontFamily: MONO, fontSize: 40, background: C.ink, color: C.paper, border: `2px solid ${C.line}`, padding: "16px 34px", borderRadius: 16, maxWidth: 1700, textAlign: "center", wordBreak: "break-word" }}>
                  <span style={{ color: C.sage }}>$ </span>{c}
                </div>
              ))}
            </div>
            <div style={{ position: "absolute", top: 770, display: "flex", gap: 30, alignItems: "center", opacity: prog(lt, 1.4, 1.9) }}>
              <div style={{ background: C.acid, color: C.ink, fontFamily: SANS, fontWeight: 600, fontSize: 52, padding: "20px 52px", borderRadius: 999 }}>★  Star on GitHub</div>
              <Mono size={40} color={C.paper}>github.com/MongLong0214/logic-pro-mcp</Mono>
            </div>
            <div style={{ position: "absolute", bottom: 160, opacity: prog(lt, 1.7, 2.1) }}><Mono size={44} color={C.acid}>logicpromcp.com</Mono></div>
            <div style={{ position: "absolute", bottom: 52, left: 70, right: 70, textAlign: "center", opacity: prog(lt, 2.0, 2.4) }}>
              <Mono size={30} color={C.sage}>v{session.meta.version} · Logic Pro {session.meta.logic} · macOS {session.meta.macos} · {session.meta.locale} · tracks and MIDI prepared in advance; every operation shown is a live MCP call</Mono>
            </div>
          </AbsoluteFill>
        );
      })()}
      <div style={{ display: "none" }}>{fmtRow("")}{total}{BAR}{bar(1)}</div>
    </AbsoluteFill>
  );
};
