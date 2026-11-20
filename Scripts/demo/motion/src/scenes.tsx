import React from "react";
import { AbsoluteFill, useCurrentFrame, useVideoConfig } from "remotion";
import { C, FPS, MONO, SANS } from "./theme";
import { outExpo, prog, inOutCubic } from "./ease";
import { Bars, Footage, Key, Kinetic, Logo, Lower, Mono, Pill, Transcript } from "./ui";
import type { Ev, Session, Take } from "./types";
import { BAR, bar, scenes } from "./timeline";

const S = (s: number) => Math.round(s * FPS);

// -------- camera presets: focal point (x, y) in footage coordinates, zoom factor. Tuned against real frames.
export const CAM = {
  // take A (mixer view): LCD, track list + arrange strip on top, mixer strips below
  aWide: { x: 0.5, y: 0.5, z: 1 },
  aTracks: { x: 0.36, y: 0.2, z: 1.9 },
  aLcd: { x: 0.5, y: 0.04, z: 3.2 },
  aMixer: { x: 0.27, y: 0.74, z: 1.75 },
  // take B (arrange view): content lives in the upper half
  bWide: { x: 0.5, y: 0.28, z: 1.35 },
  bFollowA: { x: 0.45, y: 0.22, z: 1.7 },
  bFollowB: { x: 0.62, y: 0.22, z: 1.7 },
};
const push = (a: { x: number; y: number; z: number }, b: { x: number; y: number; z: number }, f0: number, f1: number): Key[] => [
  { f: 0, ...a }, { f: f0, ...a }, { f: f1, ...b },
];

const aspectOf = (t: Take) => t.width / t.height;
const fadeOut = (frame: number, total: number, frames = 10) => 1 - prog(frame, total - frames, total, inOutCubic);

// ------------------------------------------------------------------------------------------------ 1 HOOK
export const Hook: React.FC<{ session: Session; t0?: number }> = ({ session, t0 = scenes.hook.from }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const B = session.takes.B;
  const z = 1.0 + 0.1 * prog(frame, 0, durationInFrames, inOutCubic);
  return (
    <AbsoluteFill>
      <Footage src={B.video} startFromSeconds={(B.audioOnset ?? 0) + t0} aspect={aspectOf(B)}
        keys={[{ f: 0, x: 0.5, y: 0.5, z: 1.0 }, { f: durationInFrames, x: 0.5, y: 0.46, z }]} dim={0.62} blur={10 - 8 * prog(frame, 0, 90)} />
      <AbsoluteFill style={{ background: "radial-gradient(ellipse at 30% 60%, rgba(16,21,18,0) 0%, rgba(16,21,18,0.8) 90%)" }} />
      <div style={{ position: "absolute", left: 120, top: 250 }}>
        <Kinetic text={"Talk to\nLogic Pro."} size={230} at={6} gap={9} accent={["Pro"]} lineHeight={0.96} tracking={-0.06} />
        <Mono size={26} color={C.sage} style={{ marginTop: 48, opacity: prog(frame, 60, 90) }}>A REAL SESSION · LOGIC PRO {session.meta.logic.split(" ")[0]} · RECORDED LIVE</Mono>
      </div>
      <AbsoluteFill style={{ opacity: 1 - fadeOut(frame, durationInFrames, 8), background: C.deep }} />
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------------------------------------ 2 PROBLEM
const CHIPS = ["Click", "Menu", "Drag", "Rename", "Fader", "Pan", "Mute", "Solo", "Tempo", "Click", "Scroll", "Undo", "Click", "Drag", "Menu", "Fader"];
export const Problem: React.FC = () => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const eighth = S(BAR / 8);
  return (
    <AbsoluteFill style={{ background: C.deep }}>
      <div style={{ position: "absolute", left: 120, top: 120 }}>
        <Kinetic text={"Making music is\nmostly clicking."} size={104} at={0} gap={5} accent={["clicking"]} color={C.paper} />
      </div>
      {CHIPS.map((w, i) => {
        const at = eighth * 0.5 + i * (eighth * 0.5);
        const p = prog(frame, at, at + 14, outExpo);
        const col = i % 4;
        const row = Math.floor(i / 4);
        const x = 120 + col * 420 + (row % 2) * 70;
        const y = 480 + row * 135;
        return (
          <div key={i} style={{ position: "absolute", left: x, top: y, transform: `translateY(${(1 - p) * 30}px) rotate(${((i * 7) % 5 - 2) * 0.8}deg) scale(${0.9 + 0.1 * p})`, opacity: p }}>
            <div style={{ fontFamily: MONO, fontSize: 52, padding: "16px 34px", borderRadius: 18, color: C.paper, border: `2px solid ${C.line}`, background: C.panel }}>{w}</div>
          </div>
        );
      })}
      <AbsoluteFill style={{ background: C.deep, opacity: prog(frame, durationInFrames - 12, durationInFrames) }} />
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------------------------------------ 3 REVEAL
export const Reveal: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const p1 = prog(frame, 0, 40, outExpo);
  const p2 = prog(frame, 14, 56, outExpo);
  const scaleOut = 1 + 0.04 * prog(frame, 0, 200, inOutCubic);
  return (
    <AbsoluteFill style={{ background: `radial-gradient(ellipse at 50% 55%, ${C.player} 0%, ${C.deep} 70%)`, alignItems: "center", justifyContent: "center" }}>
      <div style={{ transform: `scale(${(0.82 + 0.18 * p1) * scaleOut})`, opacity: p1 }}>
        <Logo size={150} t={t} wordProgress={p2} />
      </div>
      <div style={{ position: "absolute", top: 640 }}>
        <Kinetic text="Drive Logic Pro from any AI client." size={58} at={36} gap={4} align="center" weight={500} color={C.paper} tracking={-0.03} />
        <div style={{ display: "flex", gap: 18, justifyContent: "center", marginTop: 44, opacity: prog(frame, 80, 110) }}>
          {["Claude", "Cursor", "Codex", "VS Code"].map((n) => <Pill key={n} size={26}>{n}</Pill>)}
        </div>
      </div>
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------------------------------------ hero scenes
type HeroProps = {
  session: Session; take: "A" | "B"; startOffset: number; // footage seconds at scene start (take B: relative to the music)
  keys: Key[]; n: string; title: string; detail?: string; filter?: (e: Ev) => boolean; rows?: number;
  captionAt?: number; showTranscript?: boolean; extra?: React.ReactNode;
};
const Hero: React.FC<HeroProps> = ({ session, take, startOffset, keys, n, title, detail, filter, rows = 5, captionAt = 14, showTranscript = true, extra }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const T = session.takes[take];
  const start = take === "B" ? (T.audioOnset ?? 0) + startOffset : startOffset;
  const now = start + frame / FPS;
  const evs = filter ? T.events.filter(filter) : T.events;
  const slide = prog(frame, 6, 40, outExpo);
  return (
    <AbsoluteFill>
      <Footage src={T.video} startFromSeconds={start} aspect={aspectOf(T)} keys={keys} />
      <AbsoluteFill style={{ background: "linear-gradient(180deg, rgba(16,21,18,0) 55%, rgba(16,21,18,0.78) 100%)" }} />
      {showTranscript && (
        <div style={{ position: "absolute", right: 72, top: 72, transform: `translateX(${(1 - slide) * 80}px)`, opacity: slide }}>
          <Transcript events={evs} nowSeconds={now} width={640} rows={rows} />
        </div>
      )}
      {extra}
      <Lower n={n} title={title} detail={detail} at={captionAt} out={durationInFrames - 20} />
      <div style={{ position: "absolute", right: 72, bottom: 56, opacity: 0.8 }}>
        <Mono size={20} color={C.paper}>REAL TIME · NO SPEED-UP · LOGIC PRO {session.meta.logic.split(" ")[0]}</Mono>
      </div>
      <AbsoluteFill style={{ background: C.deep, opacity: 1 - prog(frame, 0, 8) }} />
    </AbsoluteFill>
  );
};

const firstOf = (T: Take, pred: (e: Ev) => boolean) => T.events.find(pred);

export const ReadScene: React.FC<{ session: Session }> = ({ session }) => {
  const A = session.takes.A;
  const ev = firstOf(A, (e) => e.args.includes("logic://tracks"));
  const t0 = Math.max(0, (ev?.t ?? 2) - 1.2);
  return <Hero session={session} take="A" startOffset={t0} n="01 — READ" title="Reads the whole session"
    detail={ev ? `logic://tracks · ${Math.round(ev.ms)} ms` : undefined}
    keys={push(CAM.aWide, CAM.aTracks, 20, 120)} filter={(e) => e.kind === "read"} />;
};

export const TempoScene: React.FC<{ session: Session }> = ({ session }) => {
  const A = session.takes.A;
  const ev = firstOf(A, (e) => e.call.endsWith("set_tempo"));
  const t0 = Math.max(0, (ev?.t ?? 3) - 1.0);
  return <Hero session={session} take="A" startOffset={t0} n="02 — SET" title="Sets the tempo"
    detail={ev ? `transport.set_tempo ${ev.args} · ${Math.round(ev.ms)} ms` : undefined}
    keys={push(CAM.aTracks, CAM.aLcd, 10, 90)} filter={(e) => e.call.endsWith("set_tempo")} rows={2} />;
};

export const BuildScene: React.FC<{ session: Session; t0?: number }> = ({ session, t0 = scenes.build.from }) => (
  <Hero session={session} take="B" startOffset={t0} n="03 — BUILD" title="Brings in each part, on cue"
    detail="mixer.set_volume · fader up, readback verified · the hook enters on bar 13"
    keys={push(CAM.bFollowA, CAM.bFollowB, 20, 340)} filter={(e) => e.call.endsWith("set_volume")} />
);

export const MixScene: React.FC<{ session: Session }> = ({ session }) => {
  const A = session.takes.A;
  const ev = firstOf(A, (e) => e.call.endsWith("set_volume"));
  const t0 = Math.max(0, (ev?.t ?? 5) - 0.8);
  return <Hero session={session} take="A" startOffset={t0} n="04 — MIX" title="Mixes on command"
    detail="mixer.set_volume · mixer.set_pan · read back from the strip"
    keys={push(CAM.aLcd, CAM.aMixer, 10, 80)} filter={(e) => e.call.includes("mixer")} rows={6} />;
};

// ------------------------------------------------------------------------------------------------ 5 VERIFY
export const VerifyScene: React.FC<{ session: Session }> = ({ session }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const A = session.takes.A;
  const ev = A.events.find((e) => e.call.endsWith("set_volume")) ?? A.events[0];
  const p = prog(frame, 10, 50, outExpo);
  const p2 = prog(frame, 60, 100, outExpo);
  return (
    <AbsoluteFill style={{ background: `radial-gradient(ellipse at 50% 40%, ${C.player}, ${C.deep} 75%)`, padding: 120 }}>
      <Mono size={24} color={C.acid}>05 — VERIFY</Mono>
      <Kinetic text={"Every change\nis read back."} size={132} at={4} gap={7} accent={["back."]} style={{ marginTop: 16 }} />
      <div style={{ position: "absolute", left: 120, right: 120, bottom: 120, display: "flex", gap: 40, opacity: p, transform: `translateY(${(1 - p) * 30}px)` }}>
        <div style={{ flex: 1, border: `1.5px solid ${C.line}`, borderRadius: 22, padding: 36, background: C.panel }}>
          <Mono size={22} color={C.sage}>YOU ASK</Mono>
          <div style={{ fontFamily: MONO, color: C.paper, fontSize: 34, marginTop: 14 }}>{ev?.call}</div>
          <div style={{ fontFamily: MONO, color: C.acid, fontSize: 30, marginTop: 8 }}>{ev?.args}</div>
        </div>
        <div style={{ flex: 1, border: `1.5px solid ${C.acid}`, borderRadius: 22, padding: 36, background: C.panel, opacity: p2, transform: `translateY(${(1 - p2) * 24}px)` }}>
          <Mono size={22} color={C.acid}>LOGIC ANSWERS · STATE {ev?.state}</Mono>
          <div style={{ fontFamily: MONO, color: C.paper, fontSize: 28, marginTop: 14, lineHeight: 1.35, wordBreak: "break-word" }}>{ev?.result}</div>
          <div style={{ fontFamily: MONO, color: C.sage, fontSize: 24, marginTop: 14 }}>measured {Math.round(ev?.ms ?? 0)} ms</div>
        </div>
      </div>
      <AbsoluteFill style={{ background: C.deep, opacity: 1 - prog(frame, 0, 8) }} />
      <AbsoluteFill style={{ background: C.deep, opacity: prog(frame, durationInFrames - 8, durationInFrames) }} />
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------------------------------------ 6 SPEED
export const SpeedScene: React.FC<{ session: Session }> = ({ session }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const { mixWrites, mixSeconds, medianMs, totalCalls } = session.stats;
  // The counter replays the real batch at real speed: each write increments when it actually happened.
  const mix = session.takes.A.events.filter((e) => e.call.includes("mixer"));
  const t0 = mix[0]?.t ?? 0;
  const now = t0 + frame / FPS - 0.6;
  const done = mix.filter((e) => e.t + e.ms / 1000 <= now).length;
  const elapsed = Math.min(mixSeconds, Math.max(0, now - t0));
  return (
    <AbsoluteFill style={{ background: C.deep, padding: 120 }}>
      <Mono size={24} color={C.acid}>06 — SPEED</Mono>
      <Kinetic text={"Real timings.\nNothing sped up."} size={120} at={4} gap={7} accent={["Nothing"]} style={{ marginTop: 16 }} />
      <div style={{ position: "absolute", left: 120, right: 120, bottom: 110, display: "flex", gap: 40, alignItems: "flex-end" }}>
        <div style={{ flex: 1.3 }}>
          <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 250, color: C.acid, letterSpacing: "-0.07em", lineHeight: 0.9, fontVariantNumeric: "tabular-nums" }}>{elapsed.toFixed(1)}<span style={{ fontSize: 90, color: C.paper }}> s</span></div>
          <Mono size={28} color={C.paper} style={{ marginTop: 18 }}>{done} / {mixWrites} verified mixer writes, live clock</Mono>
        </div>
        <div style={{ flex: 1, display: "grid", gap: 20 }}>
          {[[`${Math.round(medianMs)} ms`, "median MCP round trip"], [`${totalCalls}`, "calls in this film, all logged"], [`${mixWrites}`, "readback-verified fader and pan moves"]].map(([v, l], i) => (
            <div key={i} style={{ borderTop: `1.5px solid ${C.line}`, paddingTop: 16, opacity: prog(frame, 20 + i * 8, 50 + i * 8) }}>
              <div style={{ fontFamily: SANS, fontSize: 64, fontWeight: 600, color: C.paper, letterSpacing: "-0.04em" }}>{v}</div>
              <Mono size={22}>{l}</Mono>
            </div>
          ))}
        </div>
      </div>
      <AbsoluteFill style={{ background: C.deep, opacity: 1 - prog(frame, 0, 8) }} />
      <AbsoluteFill style={{ background: C.deep, opacity: prog(frame, durationInFrames - 8, durationInFrames) }} />
    </AbsoluteFill>
  );
};

// ------------------------------------------------------------------------------------------------ 7 CLOSE
export const Close: React.FC<{ session: Session }> = ({ session }) => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const p = prog(frame, 6, 50, outExpo);
  return (
    <AbsoluteFill style={{ background: `radial-gradient(ellipse at 50% 30%, ${C.player}, ${C.deep} 75%)`, alignItems: "center", justifyContent: "center" }}>
      <div style={{ position: "absolute", top: 120, opacity: p, transform: `translateY(${(1 - p) * 30}px)` }}><Logo size={86} t={t} /></div>
      <div style={{ position: "absolute", top: 330, opacity: prog(frame, 14, 54) }}>
        <Kinetic text="Your AI. Your Logic. One command." size={92} at={10} gap={5} align="center" accent={["command."]} tracking={-0.05} />
      </div>
      <div style={{ position: "absolute", top: 560, display: "grid", gap: 22, justifyItems: "center", opacity: prog(frame, 50, 84) }}>
        <div style={{ fontFamily: MONO, fontSize: 46, background: C.ink, color: C.paper, border: `1.5px solid ${C.line}`, padding: "22px 44px", borderRadius: 18 }}>
          <span style={{ color: C.sage }}>$ </span>brew install logic-pro-mcp
        </div>
        <Mono size={24} color={C.sage}>brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp</Mono>
      </div>
      <div style={{ position: "absolute", top: 800, display: "flex", gap: 28, alignItems: "center", opacity: prog(frame, 80, 114) }}>
        <div style={{ background: C.acid, color: C.ink, fontFamily: SANS, fontWeight: 600, fontSize: 44, padding: "20px 48px", borderRadius: 999, letterSpacing: "-0.02em" }}>★  Star on GitHub</div>
        <Mono size={36} color={C.paper}>github.com/MongLong0214/logic-pro-mcp</Mono>
      </div>
      <div style={{ position: "absolute", bottom: 150, opacity: prog(frame, 100, 130) }}><Mono size={34} color={C.acid}>logicpromcp.com</Mono></div>
      <div style={{ position: "absolute", bottom: 64, left: 0, right: 0, textAlign: "center", opacity: prog(frame, 110, 140) }}>
        <Mono size={19} color={C.muted}>v{session.meta.version} · Logic Pro {session.meta.logic} · macOS {session.meta.macos} · {session.meta.locale} · session prepared in advance; every operation shown is a live MCP call</Mono>
      </div>
    </AbsoluteFill>
  );
};
