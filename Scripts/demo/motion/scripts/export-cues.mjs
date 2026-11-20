// Prints the film's structure as JSON for the audio step, straight from src/timeline.ts (single source of truth).
import { TOTAL, scenes, sfx, social } from "../src/timeline.ts";
console.log(JSON.stringify({ total: TOTAL, scenes, sfx, social }, null, 1));
