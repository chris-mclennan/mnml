// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://mnml.sh',
  integrations: [
    starlight({
      title: 'mnml',
      customCss: ['./src/styles/install.css'],
      description:
        'A NvChad-style terminal IDE in Rust — vim or standard editing, LSP, git, embedded HTTP/CDP/DAP, AI panes, headless test harness.',
      // Hidden-during-dev: drop the noindex entry before public launch.
      // The og:image + Twitter card meta stay.
      head: [
        {
          tag: 'meta',
          attrs: { name: 'robots', content: 'noindex, nofollow' },
        },
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
            { label: 'Startup picker', slug: 'manual/startup-picker' },
            { label: 'Editing', slug: 'manual/editing' },
            { label: 'LSP', slug: 'manual/lsp' },
            { label: 'Git', slug: 'manual/git' },
            { label: 'HTTP client', slug: 'manual/http' },
            { label: 'AI panes', slug: 'manual/ai-panes' },
            { label: 'Headless & .test', slug: 'manual/headless' },
            { label: 'Settings & configuration', slug: 'manual/settings' },
          ],
        },
        {
          label: 'Integrations',
          items: [
            { label: 'Building integrations', slug: 'manual/integrations/building' },
            { label: 'Community integrations', slug: 'manual/integrations/community' },
            { label: 'Jira tracker viewer', slug: 'manual/integrations/tracker-jira' },
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
            { label: 'tmnl — GPU terminal', link: 'https://tmnl.sh' },
            { label: 'mixr — DJ app', link: 'https://mixr.sh' },
          ],
        },
      ],
    }),
  ],
});
