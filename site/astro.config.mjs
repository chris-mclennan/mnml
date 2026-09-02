// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

// #859 — read the mnml crate version from ../Cargo.toml at build
// time so install / index / footer can render "v0.2.0" beside the
// download links without hard-coding it in each page. The regex
// deliberately matches the FIRST top-level `version = "…"` — that
// is the [package] block, followed by any nested workspace deps.
const __dirname = dirname(fileURLToPath(import.meta.url));
const cargoToml = readFileSync(resolve(__dirname, '..', 'Cargo.toml'), 'utf8');
const versionMatch = cargoToml.match(/^version\s*=\s*"([^"]+)"/m);
const MNML_VERSION = versionMatch ? versionMatch[1] : 'unknown';

// https://astro.build/config
export default defineConfig({
  site: 'https://mnml.sh',
  vite: {
    // Compile-time constant every page can read via
    // `import.meta.env.MNML_VERSION`. Rebuilt on `npm run build`
    // whenever ../Cargo.toml changes.
    define: {
      'import.meta.env.MNML_VERSION': JSON.stringify(MNML_VERSION),
    },
  },
  integrations: [
    starlight({
      title: 'mnml',
      customCss: ['./src/styles/install.css'],
      description:
        'A NvChad-style terminal IDE in Rust — vim or standard editing, LSP, git, embedded HTTP/CDP/DAP, AI panes, headless test harness.',
      // 2026-08-17 — dropped the noindex entry per launch checklist.
      // User report: "mnml.sh" showed up in exact-quote fallback search
      // (Google's last-resort match) but no general/ranked results,
      // because every page carried `<meta name="robots" content="noindex,
      // nofollow">`. Removed. og:image + Twitter card meta stay.
      head: [
        {
          tag: 'meta',
          attrs: { property: 'og:image', content: 'https://mnml.sh/og/hero.png' },
        },
        {
          tag: 'meta',
          attrs: { property: 'og:image:width', content: '1200' },
        },
        {
          tag: 'meta',
          attrs: { property: 'og:image:height', content: '630' },
        },
        {
          tag: 'meta',
          attrs: {
            property: 'og:image:alt',
            content:
              'mnml — a terminal IDE for the people who do everything in a terminal.',
          },
        },
        {
          tag: 'meta',
          attrs: { property: 'og:type', content: 'website' },
        },
        {
          tag: 'meta',
          attrs: { name: 'twitter:card', content: 'summary_large_image' },
        },
        {
          tag: 'meta',
          attrs: { name: 'twitter:image', content: 'https://mnml.sh/og/hero.png' },
        },
        {
          tag: 'meta',
          attrs: { name: 'twitter:title', content: 'mnml — a NvChad-style terminal IDE in Rust' },
        },
        {
          tag: 'meta',
          attrs: {
            name: 'twitter:description',
            content:
              'Vim or standard editing — without `if vim {}` scattered through the codebase. LSP, git, HTTP, AI panes, headless test harness.',
          },
        },
      ],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/chris-mclennan/mnml',
        },
      ],
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'index' },
            { label: 'Install', slug: 'install' },
            { label: 'First run', slug: 'getting-started' },
          ],
        },
        {
          // Manual pages added by the `manual-writer` agent over time.
          // Order here reflects intended reading sequence.
          label: 'Manual',
          items: [
            { label: 'Workspaces & the file rail', slug: 'manual/workspaces' },
            { label: 'File actions & tree up-navigation', slug: 'manual/file-actions' },
            { label: 'Activity bar', slug: 'manual/activity-bar' },
            { label: 'Activity panels', slug: 'manual/activity-panels' },
            { label: 'Activity lists — TODOs, Notes & Findings', slug: 'manual/activity-lists' },
            { label: 'Tabs, splits & tab pages', slug: 'manual/tabs-splits' },
            { label: 'Right side panel', slug: 'manual/right-panel' },
            { label: 'Menu bar', slug: 'manual/menu-bar' },
            { label: 'Hover-help', slug: 'manual/hover-help' },
            { label: 'Bridge & Mount (sibling integration)', slug: 'manual/bridge-mount' },
            { label: 'Startup picker', slug: 'manual/startup-picker' },
            { label: 'First-launch wizard', slug: 'manual/first-launch' },
            { label: 'Word & line motion · keys.doctor', slug: 'manual/keyboard-motion' },
            { label: 'Platform support', slug: 'manual/platform-support' },
            { label: 'Running mnml over SSH', slug: 'manual/remote-ssh' },
            { label: 'Editing', slug: 'manual/editing' },
            { label: 'Statusline, gutter & F1 help', slug: 'manual/statusline-chrome' },
            { label: 'Dock widgets', slug: 'manual/dock-widgets' },
            { label: 'Sonos', slug: 'manual/sonos' },
            { label: 'Coming from NvChad', slug: 'manual/coming-from-nvchad' },
            { label: 'Coming from VS Code', slug: 'manual/coming-from-vscode' },
            { label: 'Cheatsheet — NvChad chord map', slug: 'manual/cheatsheet-nvchad' },
            { label: 'Cheatsheet — VS Code chord map', slug: 'manual/cheatsheet-vscode' },
            { label: 'Cheatsheet — all chords', slug: 'manual/cheatsheet-all' },
            { label: 'Chord chains', slug: 'manual/chord-chains' },
            { label: 'Cmdline popup', slug: 'manual/cmdline-popup' },
            { label: 'LSP', slug: 'manual/lsp' },
            { label: 'Git', slug: 'manual/git' },
            { label: 'HTTP client', slug: 'manual/http' },
            { label: 'HTTP Request pane — tabs & layout', slug: 'manual/http-edit-tabs' },
            { label: 'HTTP variables, edit split & panel filter', slug: 'manual/http-request-polish' },
            { label: 'HTTP new request (Postman-style)', slug: 'manual/http-new-request' },
            { label: 'HTTP build from natural language', slug: 'manual/http-ai-build' },
            { label: 'HTTP envs & templating', slug: 'manual/http-envs' },
            { label: 'HTTP sync — sources.json', slug: 'manual/http-sync' },
            { label: 'HTTP realistic request generation', slug: 'manual/http-generation' },
            { label: 'HTTP bench', slug: 'manual/http-bench' },
            { label: 'HTTP mocks', slug: 'manual/http-mocks' },
            { label: 'HTTP response schema validation', slug: 'manual/http-schema' },
            { label: 'HTTP chains', slug: 'manual/http-chains' },
            { label: 'HTTP history', slug: 'manual/http-history' },
            { label: 'HTTP captured browser traffic', slug: 'manual/http-captured' },
            { label: 'HTTP lookups', slug: 'manual/http-lookup' },
            { label: 'HTTP helpers — JWT & bearer', slug: 'manual/http-helpers' },
            { label: 'AI panes', slug: 'manual/ai-panes' },
            { label: 'AI launch profiles', slug: 'manual/ai-launch-profiles' },
            { label: 'Cross-host PR workflow', slug: 'manual/cross-host-prs' },
            { label: 'Headless & .test', slug: 'manual/headless' },
            { label: 'Settings & configuration', slug: 'manual/settings' },
            { label: 'Security & hardening', slug: 'manual/security' },
            { label: 'Cloud agents runner (ECS)', slug: 'manual/cloud-agents-config' },
            { label: 'Now-playing & transport', slug: 'manual/now-playing' },
            { label: 'In-app updater', slug: 'manual/updates' },
          ],
        },
        {
          label: 'Integrations',
          items: [
            { label: 'Integrations overview', slug: 'manual/integrations/overview' },
            { label: 'Installing integrations', slug: 'manual/integrations/installing' },
            { label: 'Integration auth', slug: 'manual/integrations/auth' },
            { label: 'Marketplace', slug: 'manual/integrations/marketplace' },
            { label: 'Launcher manifests', slug: 'manual/integrations/launcher-manifests' },
            { label: 'Building integrations', slug: 'manual/integrations/building' },
            { label: 'Community integrations', slug: 'manual/integrations/community' },
          ],
        },
        {
          label: 'Releases',
          items: [
            { label: 'Changelog', slug: 'changelog' },
            { label: 'Troubleshooting', slug: 'troubleshooting' },
          ],
        },
        {
          label: 'Family',
          items: [
            { label: 'The family', slug: 'family' },
            { label: 'mixr — DJ app', link: 'https://mixr.sh' },
          ],
        },
      ],
    }),
  ],
});
