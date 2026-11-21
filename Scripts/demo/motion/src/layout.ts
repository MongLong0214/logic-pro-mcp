// Where things are in the Logic capture, in normalised frame coordinates (0..1 of the captured window), measured on a
// still of the take (see docs/media/README.md). The virtual camera frames these for each write.
export type Target = { x: number; y: number; z: number };

export const LOGIC = {
  wide: { x: 0.5, y: 0.5, z: 1.0 } as Target,
  lcd: { x: 0.5, y: 0.05, z: 3.0 } as Target, // tempo and position display
  transport: { x: 0.42, y: 0.05, z: 3.0 } as Target, // play / stop buttons
  tracks: { x: 0.2, y: 0.3, z: 1.7 } as Target, // the track list, for reads
  // track header rows (name, mute/solo, volume slider, pan knob all inside one row)
  rowY: [0.189, 0.25, 0.312, 0.374, 0.435],
  rowX: 0.1,
  rowW: 0.148, // header column width (R/I buttons hidden, so the header ends at about 0.145 of the window)
  rowZ: 3.2,
};

export const rowTarget = (i: number): Target => ({ x: LOGIC.rowX, y: LOGIC.rowY[Math.max(0, Math.min(LOGIC.rowY.length - 1, i))], z: LOGIC.rowZ });
