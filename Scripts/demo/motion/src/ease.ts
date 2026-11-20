import { Easing } from "remotion";

export const outExpo = Easing.bezier(0.16, 1, 0.3, 1);
export const inOutCubic = Easing.bezier(0.65, 0, 0.35, 1);
export const linear = (x: number) => x;

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
/** 0..1 progress of time `t` (seconds) between `a` and `b`, eased. */
export const prog = (t: number, a: number, b: number, ease: (x: number) => number = outExpo) => ease(clamp01((t - a) / (b - a)));

/** Keyframed value over time: keys are [seconds, value], each segment eased. */
export function track(t: number, keys: Array<[number, number]>, ease: (x: number) => number = inOutCubic): number {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    if (t <= keys[i][0]) {
      const [t0, v0] = keys[i - 1];
      const [t1, v1] = keys[i];
      return v0 + (v1 - v0) * ease(clamp01((t - t0) / (t1 - t0)));
    }
  }
  return keys[keys.length - 1][1];
}
