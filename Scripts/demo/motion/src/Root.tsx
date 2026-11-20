import React from "react";
import { AbsoluteFill, Composition, Sequence, staticFile } from "remotion";
import { FPS } from "./theme";
import { TOTAL, scenes, social } from "./timeline";
import { BuildScene, Close, Hook, MixScene, Problem, ReadScene, Reveal, SpeedScene, TempoScene, VerifyScene } from "./scenes";
import type { Session } from "./types";
import sessionJson from "../public/data/session.json";

const session = sessionJson as unknown as Session;
void staticFile;
const fr = (s: number) => Math.round(s * FPS);
const at = (id: keyof typeof scenes) => ({ from: fr(scenes[id].from), durationInFrames: fr(scenes[id].to) - fr(scenes[id].from) });

export const Launch: React.FC = () => (
  <AbsoluteFill style={{ background: "#101512" }}>
    <Sequence {...at("hook")}><Hook session={session} /></Sequence>
    <Sequence {...at("problem")}><Problem /></Sequence>
    <Sequence {...at("reveal")}><Reveal /></Sequence>
    <Sequence {...at("read")}><ReadScene session={session} /></Sequence>
    <Sequence {...at("tempo")}><TempoScene session={session} /></Sequence>
    <Sequence {...at("build")}><BuildScene session={session} /></Sequence>
    <Sequence {...at("mix")}><MixScene session={session} /></Sequence>
    <Sequence {...at("verify")}><VerifyScene session={session} /></Sequence>
    <Sequence {...at("speed")}><SpeedScene session={session} /></Sequence>
    <Sequence {...at("close")}><Close session={session} /></Sequence>
  </AbsoluteFill>
);

const seg = (k: "hook" | "reveal" | "drop" | "close") => ({ from: fr(social[k].v[0]), durationInFrames: fr(social[k].v[1]) - fr(social[k].v[0]) });

export const Social: React.FC = () => (
  <AbsoluteFill style={{ background: "#101512" }}>
    <Sequence {...seg("hook")}><Hook session={session} t0={0} /></Sequence>
    <Sequence {...seg("reveal")}><Reveal /></Sequence>
    <Sequence {...seg("drop")}><BuildScene session={session} t0={social.drop.a} /></Sequence>
    <Sequence {...seg("close")}><Close session={session} /></Sequence>
  </AbsoluteFill>
);

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} width={1920} height={1080} fps={FPS} durationInFrames={fr(TOTAL)} />
    <Composition id="Social" component={Social} width={1920} height={1080} fps={FPS} durationInFrames={fr(social.total)} />
  </>
);
