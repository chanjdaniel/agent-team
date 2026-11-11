// The effect toolkit's test copies this app to a temporary directory and links its node_modules
// to servers/node_modules, so Vite keeps its cache in the copy and serves the linked packages.
import { foldkit } from "@foldkit/vite-plugin";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [foldkit()],
  cacheDir: ".vite-cache",
  clearScreen: false,
  server: { host: "127.0.0.1", strictPort: true, fs: { strict: false } },
});
