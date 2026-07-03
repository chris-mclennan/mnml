---
title: Azure Blob Storage browser
description: mnml-fs-azure-blob — a terminal browser for Azure Blob Storage. Storage accounts + containers + blobs with drill-down navigation, download to cache, https + SAS URL yank, portal open, blob delete. Shells out to `az`; no SDK dep.
---

[`mnml-fs-azure-blob`](https://github.com/chris-mclennan/mnml-fs-azure-blob) is a terminal browser for Azure Blob Storage. Storage accounts → containers → blobs → prefixes, download to cache, yank https URIs and SAS URLs, open the Azure Portal. Runs **standalone in any terminal**. Shells out to `az` — no SDK dep. Sibling of [`mnml-fs-s3`](/manual/integrations/fs-s3/): same TUI shape, different cloud.

```
┌─ Azure Blob ─────────────────────────────────────────────────────┐
│ ▸1.accounts  2.logs  3.exports                                    │
└──────────────────────────────────────────────────────────────────┘
┌─ logs ───────────────────────────────────────────────────────────┐
│ 📁 mystorageacct / logs / 2026 / 06                               │
└──────────────────────────────────────────────────────────────────┘
┌─ 12 entries ─────────────────────────────────────────────────────┐
│ ▸ 📁 errors/                                                      │
│   📁 access/                                                      │
│   📄 build-log.txt              1.2 MB    2026-06-06              │
│   📄 application.log            45 KB     2026-06-06              │
└──────────────────────────────────────────────────────────────────┘
  Enter drill · BS up · y URL · Y SAS · o portal · d del · r refresh · q quit
```

## Install

```sh
cargo install --git https://github.com/chris-mclennan/mnml-fs-azure-blob mnml-fs-azure-blob
mnml-fs-azure-blob --install
```

You'll also need the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) on `$PATH`, signed in (`az login`) before launching the viewer.

## Setup

```sh
az login                        # interactive browser login
az account show                 # confirm subscription
mnml-fs-azure-blob              # first-run scaffolds ~/.config/mnml-fs-azure-blob.toml
mnml-fs-azure-blob --check      # verify config + CLI state
```

## Config

```toml
refresh_interval_secs = 0       # blob listings don't churn; press `r` to refresh

[[tabs]]
name = "all accounts"
kind = "accounts"

[[tabs]]
name = "logs"
kind = "blobs"
account = "mystorageacct"       # bare account name, not the URL
container = "logs"
# prefix = "2026/"              # optional starting prefix

[[tabs]]
name = "exports"
kind = "containers"
account = "mystorageacct"
```

`kind` is one of `accounts` · `containers` (needs `account`) · `blobs` (needs `account` + `container`).

## Auth shape

Every op shells out to `az storage`. The Azure CLI's own credential chain handles auth:

- `az login` sessions work with no extra config
- Service-principal env vars (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`) flow through
- Multi-subscription: `az account set --subscription <name>` before launching
- `--auth-mode login` on every blob op means AAD RBAC applies: **Storage Blob Data Reader** to list; **Contributor** to download / delete

## Keys

| Chord | Action |
|---|---|
| `1`-`9` / `Tab` | Switch tabs |
| `↑` / `k`, `↓` / `j`, `PgUp` / `PgDn`, `g` / `G` | Navigate |
| `Enter` | Drill: account → containers → blobs → prefix; blob → download to `~/.cache/mnml-fs-azure-blob/<account>/<container>/<blob>` |
| `Backspace` / `h` | Up one level |
| `y` | Yank `https://<account>.blob.core.windows.net/…` URL |
| `Y` | Yank SAS-signed read-only URL (5-min TTL) |
| `o` | Open Azure Portal URL for the focused row |
| `d` | Delete focused blob (`y` to confirm) |
| `r` | Refresh active tab |
| `q` / `Esc` / `Ctrl+C` | Quit |

## Two run modes

### Standalone

```sh
mnml-fs-azure-blob
```

### Hosted as a mnml Pty pane

```vim
:term mnml-fs-azure-blob
```

Or `<leader>iA` after `mnml-fs-azure-blob --install`.

## File-open handoff — v0.1 vs v0.2

**v0.1 (today):** `Enter` on a blob downloads to `~/.cache/mnml-fs-azure-blob/<account>/<container>/<blob>`. Status shows the local path. Open however you like or `y`-yank for later.

**v0.2 (planned):** Hosted-pane mode emits an `OpenFile` event after download so mnml can open the file in an editor pane automatically.

**v0.3 (later):** Save-back — remember (account, container, blob) → local path, hook mnml's save event to push changes with `az storage blob upload`.

## Source

[github.com/chris-mclennan/mnml-fs-azure-blob](https://github.com/chris-mclennan/mnml-fs-azure-blob). MIT.
