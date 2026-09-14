# eslint

On every save of a `.js` / `.jsx` / `.ts` / `.tsx` file, runs
`eslint --format compact` as a hidden task and publishes what it prints
through `mnml.diagnostics.set` — so the gutter, the underline, the
statusline count, the DIAGNOSTICS panel and `]d` all treat it exactly
as they treat a language server's.

Needs `eslint` on PATH. Nothing is shown while it runs.
