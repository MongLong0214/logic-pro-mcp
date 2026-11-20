export type Ev = {
  t: number; // seconds on the footage clock (first captured frame = 0)
  ms: number; // measured round-trip of the MCP call
  kind: "tool" | "read";
  call: string; // e.g. logic_tracks.mute
  args: string; // compact JSON of params, or the resource uri
  label: string;
  state: string; // A / B / C as reported by the server, or "-" for reads
  ok: boolean;
  verified: boolean | null;
  result: string; // one-line, truncated server answer
};

export type Session = {
  film: {
    seq: string; seqStart: number; fps: number; width: number; height: number; durationSeconds: number;
    events: Ev[]; markers: Record<string, number>; musicStart: number;
  };
  stats: { writes: number; verifiedWrites: number; medianMs: number; maxMs: number; totalCalls: number };
  meta: { version: string; logic: string; macos: string; date: string; locale: string; bpm: number; bars: number };
};
