#!/usr/bin/env python3
"""Per-frame luma scan of a silent master: fails on any dropout.

  scan_frames.py video.mp4 [--max-dip 22]

A dropout is a frame whose mean luma (YAVG) departs from BOTH neighbours by more than --max-dip while the neighbours
agree with each other (an isolated spike or dip), plus any fully black frame in the middle of the film. Intentional
fades are smooth over many frames, so they never look like that.
"""
import json
import subprocess
import sys

import numpy as np


def main():
    path = sys.argv[1]
    thr = float(sys.argv[sys.argv.index("--max-dip") + 1]) if "--max-dip" in sys.argv else 22.0
    out = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", "-i", f"movie={path},signalstats", "-show_entries",
                          "frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"], capture_output=True, text=True).stdout
    y = np.array([float(v) for v in out.replace(",", " ").split() if v.strip()])
    bad = []
    for i in range(1, len(y) - 1):
        d_prev, d_next, d_nn = y[i] - y[i - 1], y[i] - y[i + 1], abs(y[i - 1] - y[i + 1])
        if abs(d_prev) > thr and abs(d_next) > thr and d_prev * d_next > 0 and d_nn < thr:
            bad.append(i)
    black = [i for i in range(5, len(y) - 5) if y[i] < 1.5]
    rep = {"frames": len(y), "isolated_dropouts": bad, "mid_film_black_frames": black, "min_luma": round(float(y.min()), 2), "pass": not bad and not black}
    print(json.dumps(rep))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
