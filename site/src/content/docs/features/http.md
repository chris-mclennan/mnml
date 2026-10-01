---
title: HTTP Client
description: mnml has an HTTP client built in — requests are plain text files in your repository, sent from the editor and answered in a pane beside them.
---

Requests live in files you can read, diff and commit: `.http`, `.rest`
or `.curl`. There is no separate app and no account; the requests sit
next to the code that serves them.

## Writing a request

A `.http` file holds one request or many, separated by `###` lines:

```http
### list users
GET {{BASE_URL}}/users?limit=10
Accept: application/json

### create a user
POST {{BASE_URL}}/users
Content-Type: application/json

{ "name": "Ada" }
```

A `.curl` file holds a `curl` command exactly as you would paste it into
a shell, so a request copied from a browser's developer tools works as
is. `http.paste_curl` turns the clipboard into a request, and
`http.copy_as` turns the current one into curl, Python, JavaScript, Go,
wget or HTTPie.

## Sending

Put the cursor in a request and run `http.send` — `space R s` in the vim
profile, `ctrl+k R s` in the standard one. The request opens in a
**request pane** beside the file and the response lands in it. Sending
again from the same block re-fires the same pane.

`space R ]` and `space R [` move between the blocks of a file, and
`http.find_request` (`space R r`, or `ctrl+shift+r` in the standard
profile) is a fuzzy picker over every request in every file of the
workspace.

## The request pane

The request half has tabs for **Params**, **Body**, **Headers**,
**Auth**, **Vars** and **Script** (the raw source). The response half
has **Body**, **Headers**, **Cookies**, **Timeline** and **Tests**.
`ctrl+enter` sends, `ctrl+s` writes the pane back into its file, and
`ctrl+1` … `ctrl+6` pick a tab.

The Body tab has a mode — raw, JSON, form-urlencoded, or multipart with
`name = @file` parts — and a JSON body is formatted when it is sent.

## Environments and variables

`{{NAME}}` in a request is filled from the active environment. An
environment is a `KEY=VALUE` file at `.mnml/env/<name>.env` in the
workspace. `http.pick_env` chooses one; `http.default_env` in
`config.zon`, or `$MNML_ENV`, sets the default. An env file edited on
disk reloads on its own.

A name that no environment defines falls back to the process
environment. A request that still names something nothing defines is
not sent: the Response box says `not sent` and names each missing
variable and the env file to add it to. With no env file in the
workspace, the pane's Env chip reads `no env`, and its picker's
`+ New env…` creates one.

## Checking and chaining

Directives in comments act on a request and its response: `@assert`
checks the status, a header or the body; `@capture` saves a value from
the response into a variable for the next request. A request can also
be validated against a JSON Schema kept beside it as
`<name>.schema.json`.

For longer flows, a **chain** (`.chain.json`) runs requests in order,
pulling values out of each response with a JSON path and feeding them
into the next. It stops at the first failure.

## More in the box

- **Cookies** are kept per workspace across sends and follow redirects
  within a host; a redirect to another host drops cookies and the
  `Authorization` header.
- **History** of every send, per workspace and across all of them.
  Credential headers are redacted before anything is written.
- **Server-Sent Events** — `http.send_streaming` shows a stream as it
  arrives.
- **Bench** — `http.bench` sends the request ten times at once and
  reports percentiles and a status breakdown.
- **Mocks** — `http.save_mock` keeps a response beside its request, and
  `http.replay_mock` shows it again without the network.
- **Import** from HAR (`http.import_har`) and Postman collections v2.1
  (`http.import_postman`); each request becomes a `.curl` file.
- **JWT** — `jwt.decode` shows a token's header and claims. It does not
  check the signature.
- **WebSocket** — `ws.connect` opens a pane for talking to a `ws://` or
  `wss://` server by hand, with keepalive pings and reconnects.

The HTTP side panel (`view.activity_http`) lists collections, envs,
chains, mocks, cookies, recent requests and captured traffic.

## From the command line

The same client runs without the UI, for scripts and CI:

```sh
mnml run api/users.http --env staging     # send the file's first request
mnml chain run flows/signup.chain.json    # run a chain
mnml discover openapi.yaml --out api/     # one .curl stub per operation
```

`mnml discover` reads an OpenAPI or Swagger spec (JSON or YAML, a file
or a URL) and writes a stub per operation under `<out>/<tag>/`.

> [!NOTE]
> mnml does not decode brotli responses. It never asks a server for
> `br`; a server that sends it anyway gets a raw body and a notice.
