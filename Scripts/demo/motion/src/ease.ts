import { Easing, interpolate } from "remotion";

export const outExpo = Easing.bezier(0.16, 1, 0.3, 1);
export const inOutCubic = Easing.bezier(0.65, 0, 0.35, 1);
export const outBack = Easing.bezier(0.34, 1.56, 0.64, 1);

/** 0..1 progress of `frame` between two frames, eased. */
export const prog = (frame: number, from: number, to: number, ease = outExpo) =>
  interpolate(frame, [from, to], [0, 1], { easing: ease, extrapolateLeft: "clamp", extrapolateRight: "clamp" });

/** Keyframed value: keys are [frame, value] pairs, each segment eased. */
export function track(frame: number, keys: Array<[number, number]>, ease = inOutCubic): number {
  if (frame <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    if (frame <= keys[i][0]) {
      const [f0, v0] = keys[i - 1];
      const [f1, v1] = keys[i];
      return interpolate(frame, [f0, f1], [v0, v1], { easing: ease });
    }
  }
  return keys[keys.length - 1][1];
}
