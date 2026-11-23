// Brand tokens copied from the landing site (logicpromcp.com, DESIGN.md "Session Desk" + session player):
// paper #f1f0eb, ink #1c211f, acid #d4ed77, player green #1d2320, sage #819781. Helvetica Neue and SF Mono are
// the site's own font stacks, so the film and the page read as one product.
export const C = {
  paper: "#f1f0eb",
  ink: "#1c211f",
  deep: "#101512",
  player: "#1d2320",
  panel: "#202721",
  acid: "#d4ed77",
  sage: "#819781",
  muted: "#58615d",
  line: "#2c3530",
  warn: "#e8b25a",
};

export const SANS = '"Helvetica Neue", Helvetica, Arial, sans-serif';
export const MONO = '"SF Mono", SFMono-Regular, Menlo, Consolas, monospace';

export const FPS = 60;
export const sec = (s: number) => Math.round(s * FPS);
