import {defineConfig} from "vite";
import react from "@vitejs/plugin-react";

// Relative base so the built site works from IPFS/eth.limo or any subpath.
export default defineConfig({
  base: "./",
  plugins: [react()],
});
