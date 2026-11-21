export type Ev = {
  t: number; // seconds on the take clock (first Logic frame = 0) when the request left the client
  t_end: number; // when the reply came back
  ms: number; // round trip measured at the server boundary by mcp_tap.py
  kind: "tool" | "read";
  call: string; // e.g. logic_mixer.set_volume, or "read"
  target?: string; // for reads: tracks, transport/state, ...
  params?: Record<string, unknown>;
  state?: string;
  ok: boolean;
  verified?: boolean | null;
  track?: number | null;
  track_name?: string | null;
  what?: string; // "Pad fader", "Tempo", "Transport"
  before_after?: string; // "0.00 → 0.80"
  noop?: boolean;
  summary?: string;
  result?: string;
};

export type Prompt = { text: string; t_start: number; t_enter: number; t_idle: number };

export type Session = {
  film: {
    fps: number; seqStart: number;
    take: { seq: string; width: number; height: number; duration: number; frames?: number };
    client: { seq: string; width: number; height: number; duration: number; offset: number; frames?: number };
    events: Ev[]; prompts: Prompt[]; musicStart: number | null; playAt: number | null; stopAt: number | null;
  };
  stats: { calls: number; writes: number; realWrites: number; noopWrites: number; verifiedRealWrites: number; medianMs: number | null; maxMs: number | null; minMs: number | null };
  meta: { version: string; logic: string; macos: string; date: string; locale: string; bpm: number; client: string; model: string };
};
