import path from "node:path";
import { fileURLToPath } from "node:url";

import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
  resolve: {
    alias: {
      buffer: "buffer",
      "node:buffer": "buffer",
    },
    dedupe: ["@mysten/sui"],
  },
  define: {
    global: "globalThis",
  },
  optimizeDeps: {
    include: ["@mysten/sui", "@pythnetwork/pyth-sui-js", "buffer"],
  },
});
