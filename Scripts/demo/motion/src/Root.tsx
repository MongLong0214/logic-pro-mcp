import React from "react";
import { Composition } from "remotion";
import { FPS } from "./theme";
import { LaunchFilm, FilmProvider, TimeMap, WithTau } from "./film";
import { SONG, social, vOfFootage } from "./timeline";
import type { Session } from "./types";
import sessionJson from "../public/data/session.json";

const session = sessionJson as unknown as Session;
const P = vOfFootage(session.film.musicStart);

// Launch: composition time is film time. Ends when the song does.
const launchMap: TimeMap = [{ s0: 0, len: P + SONG, tau0: 0 }];
const LAUNCH_LEN = P + SONG;

// Social: pre-roll, the drums and hook entering, the end card; same scenes, cut on bar lines.
const socialMap: TimeMap = (() => {
  let s = 0;
  const out: TimeMap = [];
  for (const seg of social.segments) {
    if (seg.kind === "pre") { out.push({ s0: s, len: P, tau0: 0 }); s += P; }
    else { out.push({ s0: s, len: seg.len, tau0: P + (seg as { from: number }).from }); s += seg.len; }
  }
  return out;
})();
const SOCIAL_LEN = socialMap[socialMap.length - 1].s0 + socialMap[socialMap.length - 1].len;

export const Launch: React.FC = () => <FilmProvider session={session}><WithTau map={launchMap}><LaunchFilm /></WithTau></FilmProvider>;
export const Social: React.FC = () => <FilmProvider session={session}><WithTau map={socialMap}><LaunchFilm /></WithTau></FilmProvider>;

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} width={1920} height={1080} fps={FPS} durationInFrames={Math.round(LAUNCH_LEN * FPS)} />
    <Composition id="Social" component={Social} width={1920} height={1080} fps={FPS} durationInFrames={Math.round(SOCIAL_LEN * FPS)} />
  </>
);
