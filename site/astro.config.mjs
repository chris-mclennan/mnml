import { defineConfig } from "astro/config";

// Plain Astro, static output, no integrations: the chrome (navbar, docs
// sidebar, sidecar) is hand-written in src/components and src/layouts,
// and markdown is rendered by src/lib/markdown.mjs so the generated
// reference pages and the written pages go through one renderer.
export default defineConfig({
  site: "https://mnml.sh",
  output: "static",
  trailingSlash: "ignore",
  build: { format: "directory" },
  devToolbar: { enabled: false },
});
