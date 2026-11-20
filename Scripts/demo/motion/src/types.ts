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

export type Take = {
  video: string; // path under public/
  width: number;
  height: number;
  durationSeconds: number;
  events: Ev[];
  markers: Record<string, number>; // name -> footage seconds
  audioOnset?: number; // footage seconds of the first music sample (take B)
};

export type Session = {
  takes: { A: Take; B: Take };
  stats: { mixWrites: number; mixSeconds: number; medianMs: number; totalCalls: number; verifiedCalls: number };
  meta: { version: string; logic: string; macos: string; date: string; locale: string; bpm: number; bars: number };
};
