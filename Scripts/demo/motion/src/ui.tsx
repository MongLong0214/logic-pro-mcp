import React from "react";
import { AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { CameraMotionBlur } from "@remotion/motion-blur";
import { C, FPS, MONO, SANS } from "./theme";
import { outBack, outExpo, prog, track } from "./ease";
import type { Ev } from "./types";

export const MOTION_BLUR = process.env.REMOTION_MOTION_BLUR === "1";
// Multi-GB 4K footage is served over HTTP by build.sh (REMOTION_FOOTAGE_BASE) so each render does not copy it into the bundle.
const footageUrl = (p: string) => (process.env.REMOTION_FOOTAGE_BASE ? `${process.env.REMOTION_FOOTAGE_BASE}/${p.split("/").pop()}` : staticFile(p));

// ---------------------------------------------------------------- footage + camera
export type Key = { f: number; x: number; y: number; z: number };

/** Real Logic footage under a smooth virtual camera. (x, y) is the focal point in footage coordinates 0..1. */
export const Footage: React.FC<{
  src: string; startFromSeconds: number; keys: Key[]; dim?: number; blur?: number; aspect: number; saturate?: number;
}> = ({ src, startFromSeconds, keys, dim = 0, blur = 0, aspect, saturate = 1 }) => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const x = track(frame, keys.map((k) => [k.f, k.x] as [number, number]));
  const y = track(frame, keys.map((k) => [k.f, k.y] as [number, number]));
  const z = track(frame, keys.map((k) => [k.f, k.z] as [number, number]));
  // "cover" the stage with the footage rectangle, then place the focal point at the stage centre.
  const fw = Math.max(width, height * aspect);
  const fh = fw / aspect;
  const tx = width / 2 - x * fw * z;
  const ty = height / 2 - y * fh * z;
  const inner = (
    <div style={{ position: "absolute", left: 0, top: 0, width: fw, height: fh, transformOrigin: "0 0",
      transform: `translate(${tx}px, ${ty}px) scale(${z})`, filter: `blur(${blur}px) saturate(${saturate}) brightness(${1 - dim})` }}>
      <OffthreadVideo src={footageUrl(src)} startFrom={Math.round(startFromSeconds * FPS)} muted style={{ width: fw, height: fh }} />
    </div>
  );
  return (
    <AbsoluteFill style={{ background: C.deep, overflow: "hidden" }}>
      {MOTION_BLUR ? <CameraMotionBlur samples={6} shutterAngle={120}>{inner}</CameraMotionBlur> : inner}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- type
/** Words rise in one after another; `at` is the first word's frame, `gap` the frames between words. */
export const Kinetic: React.FC<{
  text: string; at?: number; gap?: number; size: number; color?: string; accent?: string[]; weight?: number;
  align?: "left" | "center"; lineHeight?: number; tracking?: number; style?: React.CSSProperties;
}> = ({ text, at = 0, gap = 5, size, color = C.paper, accent = [], weight = 600, align = "left", lineHeight = 1.0, tracking = -0.045, style }) => {
  const frame = useCurrentFrame();
  const lines = text.split("\n");
  let i = 0;
  return (
    <div style={{ fontFamily: SANS, fontSize: size, fontWeight: weight, color, lineHeight, letterSpacing: `${tracking}em`, textAlign: align, ...style }}>
      {lines.map((line, li) => (
        <div key={li} style={{ display: "flex", justifyContent: align === "center" ? "center" : "flex-start", flexWrap: "wrap", gap: `0 ${size * 0.26}px` }}>
          {line.split(" ").map((w) => {
            const p = prog(frame, at + gap * i++, at + gap * (i - 1) + 22, outExpo);
            const accentOn = accent.includes(w.replace(/[.,]/g, ""));
            return (
              <span key={w + i} style={{ display: "inline-block", overflow: "hidden", paddingBottom: size * 0.12, marginBottom: -size * 0.12 }}>
                <span style={{ display: "inline-block", transform: `translateY(${(1 - p) * 105}%)`, opacity: Math.min(1, p * 2.2), color: accentOn ? C.acid : color }}>{w}</span>
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

export const Mono: React.FC<{ children: React.ReactNode; size: number; color?: string; style?: React.CSSProperties }> = ({ children, size, color = C.sage, style }) => (
  <div style={{ fontFamily: MONO, fontSize: size, color, letterSpacing: "0.04em", ...style }}>{children}</div>
);

// ---------------------------------------------------------------- brand
export const Bars: React.FC<{ size: number; t: number; color?: string }> = ({ size, t, color = C.acid }) => {
  const h = [0.42, 1, 0.68];
  return (
    <div style={{ display: "flex", gap: size * 0.12, alignItems: "flex-end", height: size, width: size * 0.84 }}>
      {h.map((base, i) => {
        const wob = 0.5 + 0.5 * Math.sin(t * 5.2 + i * 1.9);
        return <div key={i} style={{ flex: 1, height: `${(base * 0.72 + wob * 0.28 * base) * 100}%`, background: color, borderRadius: size * 0.05 }} />;
      })}
    </div>
  );
};

export const Logo: React.FC<{ size: number; t: number; word?: boolean; wordProgress?: number }> = ({ size, t, word = true, wordProgress = 1 }) => (
  <div style={{ display: "flex", alignItems: "center", gap: size * 0.32 }}>
    <div style={{ width: size * 1.35, height: size * 1.35, borderRadius: size * 0.34, background: C.deep, display: "flex",
      alignItems: "center", justifyContent: "center", boxShadow: `0 0 0 ${size * 0.025}px ${C.line}` }}>
      <Bars size={size * 0.74} t={t} />
    </div>
    {word && (
      <div style={{ fontFamily: SANS, fontSize: size, fontWeight: 600, letterSpacing: "-0.05em", color: C.paper,
        opacity: wordProgress, transform: `translateX(${(1 - wordProgress) * -30}px)` }}>
        Logic Pro <span style={{ color: C.acid }}>MCP</span>
      </div>
    )}
  </div>
);

// ---------------------------------------------------------------- captions
/** Lower-third naming the step: index chip, bold title, mono detail line. Same style on every beat. */
export const Lower: React.FC<{ n: string; title: string; detail?: string; at: number; out?: number; scale?: number; vertical?: boolean }> = ({ n, title, detail, at, out, scale = 1, vertical }) => {
  const frame = useCurrentFrame();
  const pin = prog(frame, at, at + 24, outExpo);
  const pout = out ? prog(frame, out, out + 14, outExpo) : 0;
  const a = pin * (1 - pout);
  return (
    <div style={{ position: "absolute", left: vertical ? 56 : 96, bottom: vertical ? 300 : 92, opacity: a,
      transform: `translateY(${(1 - pin) * 40 + pout * -20}px)`, display: "flex", alignItems: "stretch", gap: 22 * scale }}>
      <div style={{ width: 6 * scale, background: C.acid, borderRadius: 3 }} />
      <div>
        <Mono size={22 * scale} color={C.acid}>{n}</Mono>
        <div style={{ fontFamily: SANS, fontWeight: 600, fontSize: 64 * scale, letterSpacing: "-0.045em", color: C.paper, lineHeight: 1.05,
          textShadow: "0 2px 24px rgba(0,0,0,0.55)" }}>{title}</div>
        {detail && <Mono size={24 * scale} color={C.paper} style={{ opacity: 0.78, marginTop: 8 * scale, textShadow: "0 2px 16px rgba(0,0,0,0.7)" }}>{detail}</Mono>}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------- transcript (rendered from the real driver log)
export const Transcript: React.FC<{ events: Ev[]; nowSeconds: number; width: number; rows?: number; fontSize?: number; title?: string }> = ({ events, nowSeconds, width, rows = 7, fontSize = 22, title = "MCP client" }) => {
  const shown = events.filter((e) => e.t <= nowSeconds).slice(-rows);
  return (
    <div style={{ width, background: "rgba(16,21,18,0.92)", border: `1px solid ${C.line}`, borderRadius: 18, overflow: "hidden",
      boxShadow: "0 30px 80px rgba(0,0,0,0.55)", fontFamily: MONO, backdropFilter: "blur(14px)" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "14px 20px", borderBottom: `1px solid ${C.line}`, color: C.sage, fontSize: fontSize * 0.8 }}>
        {[0, 1, 2].map((i) => <div key={i} style={{ width: 11, height: 11, borderRadius: 6, background: C.line }} />)}
        <span style={{ marginLeft: 8 }}>{title} · stdio · LogicProMCP 3.19.0</span>
      </div>
      <div style={{ padding: "16px 20px", minHeight: rows * fontSize * 2.95 }}>
        {shown.map((e, i) => {
          const age = nowSeconds - e.t;
          const p = Math.min(1, age * 6);
          return (
            <div key={`${e.t}-${i}`} style={{ marginBottom: fontSize * 0.7, opacity: 0.45 + 0.55 * (i / Math.max(1, shown.length - 1) || 1), transform: `translateY(${(1 - p) * 12}px)` }}>
              <div style={{ color: C.acid, fontSize }}>▸ {e.call} <span style={{ color: C.paper, opacity: 0.8 }}>{e.args}</span></div>
              <div style={{ color: e.ok ? C.sage : C.warn, fontSize: fontSize * 0.88, marginTop: 4 }}>
                {e.ok ? "✓" : "!"} {e.result} <span style={{ color: C.paper, opacity: 0.55 }}>· {Math.round(e.ms)} ms</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};

export const Pill: React.FC<{ children: React.ReactNode; size: number; filled?: boolean }> = ({ children, size, filled }) => (
  <div style={{ display: "inline-flex", padding: `${size * 0.35}px ${size * 0.8}px`, borderRadius: 999, fontFamily: MONO, fontSize: size,
    background: filled ? C.acid : "transparent", color: filled ? C.ink : C.paper, border: `1.5px solid ${filled ? C.acid : C.sage}`, letterSpacing: "0.03em" }}>{children}</div>
);

export const outBackEase = outBack;
