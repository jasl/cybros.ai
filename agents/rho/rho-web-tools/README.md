# rho-web-tools

A web reader for rho's agent loop, as an extension: one tool, `web_fetch
{url}`, that GETs a public http:// or https:// URL, converts HTML to
markdown, returns other text as-is and saves an image or other binary to a
file the model can `read` — and one verb, `rho web fetch URL`, that prints
what the model would read.

## One sentence, and what it rules out

`web_fetch` is a read of the open world. It sends a GET and nothing else —
no body, no cookies, no `Authorization`, an honest `User-Agent`
(`rho-web-tools/<version>`) a site's operator can allowlist — through httpx with
its SSRF filter on every RESOLVED address, follows redirects on the same
site up to three and REPORTS a redirect to another site, reads at most
5.0MB, gives up after 30 s, renders, and answers under the runner's own
truncation caps. Nothing here changes Nexus or the SDK: the tool is
announced `read_only` on the OPEN world, which the kernel's closed
vocabulary already carries; the rule grammar already walks `url`.

## Wanted, not merely installed

```json
{
  "plugins": {
    "rho.web_tools": {
      "enabled": true,
      "configuration": {
        "allow_private_network": false
      }
    }
  }
}
```

The distributed plugin is enabled by default in full and runner modes. An explicit
disabled setting remains disabled. Change it in Settings → Plugins or with
`rho extensions enable rho.web_tools` / `rho extensions disable rho.web_tools`.
Configure it in Settings → Plugins, including while disabled. The static schema
owns its single boolean, `allow_private_network`, whose default is `false`.
An invalid hand-written value falls back to that default with a diagnostic; an
invalid interactive edit is rejected. Existing accepted calls retain the settings
with which their tool contribution was registered.

## What the model reads

One status line, a blank line, the rendering under the caps, and — when
cut — bash's own footer:

```
https://docs.ruby-lang.org/en/master/String.html — 200 text/html; 312.4KB fetched, 41.7KB markdown (1 redirect); title: class String - Documentation for Ruby master

# class String
…

[Showing lines 1-1204 of 3310 (50.0KB limit). Full output: /Users/me/.rho/…/artifacts/web-3f9a1c2e7b0d4e61.md]
```

- The bound is the runner's `Truncation.truncate_head` with its defaults —
  2000 lines or 50.0KB, whichever first. ONLY when cut, the whole
  rendering is written to the runner's artifacts directory and the footer
  names it, so the model pages the rest with `read {path, offset}` as it
  pages a bash spill; `read` is in rho's reads allow row, so paging never
  parks. The spill path rides `files:` so a client fetches the page as a
  capture. The file is named by its content — `web-` and the first sixteen
  hex digits of its SHA-256 — so a re-fetch of an unchanged page names the
  same path and reads as the same result.
- HTML is parsed by nokogiri's HTML5 parser with `script`, `style`,
  `noscript`, `template`, `svg`, `iframe`, `object` and `embed` removed,
  the `<title>` lifted into the status line, and converted by
  reverse_markdown (no readability pass: navigation noise is the head's
  cost, and `read offset` the remedy). `text/*`, JSON, XML and JavaScript
  are verbatim. Everything else — an image, a PDF, an archive — is saved
  as `web-<digest><ext>`, named by content the same way, and the status
  line names the path; `read` on an image answers `image attached`, so a
  picture reaches a vision model through the plane's own two verbs. A PDF
  gets no text extraction.
- The charset is the `Content-Type`'s when present, else nokogiri's own
  `<meta charset>` detection, else UTF-8; invalid bytes are replaced,
  never fatal; zero-width and bidi characters and every control byte but
  newline, tab and carriage return are stripped from the rendering, so the
  model reads none.
- The render input is cut at 1.0MB before the parse (the converter is
  superlinear past a megabyte: 1 MiB 1.4 s, 2 MiB 11 s, 5 MiB unfinished at
  330 s on the dev machine, measured 2026-09-15); the cut is named in the
  status line as `rendered the first 1.0MB of 3.2MB`. The whole page's
  bytes were still read and counted under the wire cap.
- A 4xx/5xx, or a 3xx that names no `Location`, is DATA: `<url> answered
  404 Not Found` and the body's first 512 bytes — an API's error JSON is
  the model's to read.
- `structured_content` (the UI's channel) carries `url`, `final_url`,
  `status`, `content_type`, `bytes` and the truncation details.

## What is refused, and with which sentence

Before any socket, in this order, each ONE sentence the model reads and
corrects the call by:

- not a URL, or any non-ASCII byte — `url is not a valid URL; percent-encode
  non-ASCII characters in the path and query, and write the host in
  lowercase ASCII`. Nothing is normalized: your approval rules match
  `tool_input.url` exactly as the model wrote it, so a URL the tool
  rewrote would run under a rule that saw different text.
- a scheme other than http/https — `url must be http:// or https://`. No
  silent upgrade of http to https: a local dev server is http, and a
  `match: "http://…"` rule would miss an upgraded URL.
- credentials before the host — `url carries credentials before the host;
  web_fetch sends none — remove them and call again` (the sentence names
  nothing of them: that position is where tokens ride).
- a host not written in lowercase ASCII, with a trailing dot, with a
  percent-escape, or an IPv4 literal that is not four dotted decimals
  (`0x0a000005`, `167772165`, `10.0.5` — every one a spelling
  `getaddrinfo` accepts) — `url host "CORP.INTERNAL" is not canonical; write
  it in lowercase ASCII without a trailing dot, an IPv4 address as four
  dotted decimals`. This is what makes a `url` rule spelling-proof: an
  operator's deny on `*.corp.internal*` cannot be walked around. An IPv6
  literal in brackets passes to the address filter.

At resolution, by httpx's `ssrf_filter` on every address a name resolves
to (so a public name rebound to `10.0.0.1` is refused as `localhost` is,
and every redirect hop is a new connection through the same filter):
loopback, RFC 1918, link-local, CGNAT, unique-local, the documentation,
benchmark, multicast and reserved ranges — `<host> resolves to a private or
reserved address; web_fetch reaches public hosts only (settings.json "plugins.rho.web_tools.configuration":
{"allow_private_network": true} lifts loopback and RFC 1918)`. The lift is
loopback and RFC 1918 ONLY: httpx consults the safe list first, so lifting
`fc00::/7` would admit AWS's IPv6 metadata endpoint; `169.254.169.254`,
`169.254.170.2`, `169.254.169.253`, `100.100.100.200` and `[fd00:ec2::254]`
stay refused under the lift, pinned by name.

On the wire: a `Content-Length` over 5.0MB is refused at the first chunk
with nothing counted; a body that passes 5.0MB decoded is refused by the
client's own count (the wall against a gzip bomb); one deadline of 30 s
armed before resolve/connect/TLS (the SDK's `HttpDeadline`) walls the whole
chain; a cross-site redirect — `redirect: <url> → <location> (302); web_fetch
follows redirects on the same site only — call web_fetch with the new url
to follow it` — is reported because your approval is URL-shaped: a per-host
allow must not carry to another host. Same site = same scheme, same port,
hosts equal after one leading `www.`, judged against the URL the model
wrote on every hop; https → http is never followed. Every wrapped error
names the host and the cause, never the URL's query, never a backtrace.

Successful status lines count every followed redirect, up to three, even
when intermediate responses have empty bodies. The fetch log uses the same
count. Refused redirect targets are never fetched.

## Approval

`web_fetch` is a `read_only` tool on the OPEN world and is NOT in rho's
reads allow row: it runs under `bypass` (rho's daily mode), parks under
`ask` (`rho do --approval ask`; `rho approve` releases it; the spill's
`read` after it never parks), and is refused under `rules` until a rule
allows it. It gets NO ask row of its own, because the kernel collects
every matching rule with `ask` beating `allow`: an ask row would defeat
every per-host allow — the operator's `{tool: web_fetch, path: url, match:
"https://docs.ruby-lang.org/*", verdict: allow}` and the grant verb's. A
deny on `url` binds under every mode.

`rho approve LOOP KEY --always` on a held `web_fetch` approves that call
and grants the URL's literal `scheme://host[:port]/*` for the rest of the
daemon's life. The console offers **Allow this site until restart**.
`--match SITE` also creates that grant and accepts only the held URL's site,
with an optional trailing `/`; paths, queries, fragments, credentials and
wildcards are refused. For example, `https://docs.ruby-lang.org/en/` produces
`https://docs.ruby-lang.org/*`, never a grant for every `web_fetch`.

Matching uses the original URL text: another initial host or subdomain
(including `www`), scheme, port or spelling needs its own approval. An
explicit default port remains explicit. Bare site URLs without `/`, including
`https://docs.ruby-lang.org?query`, need approval again; the held call itself
is still released once. Use a slash before the path or query for subsequent
calls to match. The slash also prevents a grant from matching a host suffix
such as `docs.ruby-lang.org.example.com`.

The grant checks the initial URL. Redirects retain the same-site policy
described above, including the existing leading-`www` equivalence. Grants
are visible in `rho rules`, disappear at daemon restart, and never enter
`settings.json`.

## Logs

The daemon's log names the HOST, never the URL: `web.fetch host=… status=…
content_type=… bytes=… rendered_bytes=… redirects=… ms=…`; `web.refused
host=… reason=…`; `web.failed host=… error_class=… ms=…`. A signed URL is
a legitimate read a model was handed; what keeps its secret is that no log
line carries a URL, and `debug_redact` keeps an `HTTPX_DEBUG` line clean.

## Cancellation

A tool blocked in resolve, connect, TLS or a stalled read cannot poll the
runner's cancellation, and httpx's `Session#close` from another thread
reaches nothing in flight (the live connection is checked out of the pool
— measured). So the cancel is observed ON the blocked thread, at a bounded
cadence: the session's selector tick reads the worker's own
`ExecutionContext` and expires every open request the way the deadline
does; a 0.2 s timer bounds the wait. A cancel returns within a second.

## The verb

`rho web fetch URL [--raw]` runs the client and the render in the CLI
process against the settings file's `web` table and prints the status line
to stderr and the WHOLE rendering to stdout — no truncation, no spill (the
cap is the model's defence) — with every invisible byte escaped; `--raw`
prints the bytes as rendered; a binary answer is its bytes to stdout,
always raw (redirect it). A refusal is the sentence the model would read,
exit 1.

## The seam

The gem boundary is the split-out seam: a tools-provider process later
hosts the same `Client` and `Render` behind the SDK's executor door with
the adapter's `ToolEnv` lines (the artifacts directory, `files:`) changed.
Nothing else in the tree knows it runs on the runner's row.

## Not built, on purpose

No readability pass (2–2 among the references), no PDF text, no cache (the
spill is the durable copy and the footer names it), no browser
`User-Agent` (a 403 is data; rho has a real browser beside this), no
untrusted-content wrapper around fetched text (1-of-4; the plane's control
is the effect profile and the approval stage), no `format` parameter (the
two coding references agree on `url` alone), no proxy (`HTTPS_PROXY` is
ignored — a proxy resolves names itself).
