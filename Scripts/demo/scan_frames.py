#!/usr/bin/env python3
"""Per-frame luma scan of a video (master or deliverable, any container ffmpeg reads, GIF included): fails on any
dropout.

  scan_frames.py video.mp4 [--max-dip 3]

A dropout is a frame whose mean luma (YAVG) departs from BOTH neighbours by more than --max-dip in the same direction
while the neighbours agree with each other within --max-dip (an isolated spike or dip), plus any fully black frame in
the middle of the film. Intentional fades and cuts are not isolated (a fade is smooth, a cut changes level once), so a
threshold of 3 luma catches a single blank frame even under a dimmed card, where v2's 22 missed a 5.4 dip.
The report also gives the largest isolated deviation seen, so a pass says how close it came.
"""
import json
import subprocess
import sys

import numpy as np


def lumas(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", "-i", f"movie={path},signalstats", "-show_entries",
                          "frame_tags=lavfi.signalstats.YAVG", "-of", "csv=p=0"], capture_output=True, text=True).stdout
    return np.array([float(v) for v in out.replace(",", " ").split() if v.strip()])


def main():
    path = sys.argv[1]
    thr = float(sys.argv[sys.argv.index("--max-dip") + 1]) if "--max-dip" in sys.argv else 3.0
    y = lumas(path)
    if len(y) < 3:
        print(json.dumps({"file": path, "frames": len(y), "pass": False, "error": "no frames read"}))
        sys.exit(1)
    bad, worst = [], (0.0, -1)
    for i in range(1, len(y) - 1):
        d_prev, d_next, d_nn = y[i] - y[i - 1], y[i] - y[i + 1], abs(y[i - 1] - y[i + 1])
        if d_prev * d_next > 0:
            dev = min(abs(d_prev), abs(d_next)) - d_nn
            if dev > worst[0]:
                worst = (dev, i)
            if abs(d_prev) > thr and abs(d_next) > thr and d_nn < thr:
                bad.append(i)
    black = [i for i in range(5, len(y) - 5) if y[i] < 1.5]
    rep = {"file": path, "threshold_luma": thr, "frames": len(y), "isolated_dropouts": bad, "mid_film_black_frames": black,
           "largest_isolated_deviation": round(worst[0], 2), "at_frame": worst[1],
           "min_luma": round(float(y.min()), 2), "pass": not bad and not black}
    print(json.dumps(rep))
    sys.exit(0 if rep["pass"] else 1)


if __name__ == "__main__":
    main()
