import React from "react";
import { Composition } from "remotion";
import { FPS } from "./theme";
import { LaunchFilm, FilmProvider, WithTau, type TimeMap } from "./film";
import { plan } from "./timeline";
import type { Session } from "./types";
import sessionJson from "../public/data/session.json";

const session = sessionJson as unknown as Session;
const P = plan(session);

// Launch: composition time is film time, start to end.
const launchMap: TimeMap = [{ s0: 0, len: P.total, tau0: 0 }];
// Social (16:9) and Vertical (9:16): headline and the first request, the "play" request through the drop (ending on a
// bar line), the end card. Same scenes, same clock, so the cuts can never disagree with the film.
const socialMap: TimeMap = P.social;
const SOCIAL_LEN = socialMap[socialMap.length - 1].s0 + socialMap[socialMap.length - 1].len;
const frames = (s: number) => Math.round(s * FPS);

export const Launch: React.FC = () => <FilmProvider session={session}><WithTau map={launchMap}><LaunchFilm /></WithTau></FilmProvider>;
export const Social: React.FC = () => <FilmProvider session={session}><WithTau map={socialMap}><LaunchFilm /></WithTau></FilmProvider>;

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} width={1920} height={1080} fps={FPS} durationInFrames={frames(P.total)} />
    <Composition id="Social" component={Social} width={1920} height={1080} fps={FPS} durationInFrames={frames(SOCIAL_LEN)} />
    <Composition id="Vertical" component={Social} width={1080} height={1920} fps={FPS} durationInFrames={frames(SOCIAL_LEN)} />
  </>
);
