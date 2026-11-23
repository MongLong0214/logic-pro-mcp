import { Config } from "@remotion/cli/config";

// Chrome ships with the Mac; no download needed. Override with REMOTION_BROWSER if it lives elsewhere.
Config.setBrowserExecutable(process.env.REMOTION_BROWSER ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
Config.setVideoImageFormat("png");
Config.setPixelFormat("yuv420p");
Config.setCodec("h264");
Config.setCrf(14);
Config.setOverwriteOutput(true);
