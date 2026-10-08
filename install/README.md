# Installing Cybros and rho

## Nexus and rho with Docker

For Nexus, PostgreSQL and rho together, use the
[combined stack guide](stack/README.md). The host needs Docker with Compose v2
already running and a POSIX shell; no host Ruby or JavaScript runtime is needed.
Download and run the public installer with `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

Follow [Getting started](../docs/getting-started.md) through the first
conversation. The stack guide covers unattended setup, LAN access, configuration,
updates and backups. For building and publishing images, see the
[image guide](docker/README.md). The rest of this page describes host installation.

## rho directly on the host

Clone the public repository and run the installer from its root:

```sh
git clone https://github.com/jasl/cybros.ai.git
cd cybros.ai
bash install/install.sh
```

An existing checkout can run `bash install/install.sh` directly. Keep the clone
after installation: it supplies future updates. The public `main` branch follows
the rolling release.

The host installer builds from the checkout. `rho update` fast-forwards that checkout and re-runs *its* copy of this script; the commits
it pulled are printed before the script runs, so what runs is what you can read. Whatever branch is
checked out is what rolls — a user on `release` rolls on release, a developer on `main` on main;
`rho update` never switches branches. What lands is the MANAGEMENT CLI — `server`, `connect`/`disconnect`/`status`,
`version`/`doctor`/`update`/`uninstall`, the shipped gems' verbs — and one conversation verb, `rho run`; the verbs
that operate a conversation from a terminal (`do`, `say`, `watch`, …) are `rho-dev`'s, a development gem the
checkout's e2e supplies (`agents/rho/rho-dev/README.md`) and no manifest row, image or `rho doctor` row names.

The package includes `rho-webui`, whose ready-to-serve HTML, CSS and JavaScript are served by the
Ruby daemon in `full` and `agent` modes. There is no Node, Deno or Bun server to install or run for
the WebUI. `runner` mode is headless by default; `RHO_API_ONLY=1` disables the page in any mode.
The `dev` install profile adds Playwright for the model's browser tools, not for the WebUI.
`rho-web-tools` provides web reading by default in `full` and `runner` modes.
Disable it through the `rho.web_tools` plugin in Settings or
`rho extensions disable rho.web_tools`; an explicit saved disable remains effective.
See [Deploying rho](../docs/rho-deploy.md) for
console access and headless deployment.

`rho-codemode` supplies the `code` tool and loads by default in full, agent and runner
modes, including headless deployments. It serves each available agent and runner executor
address; named agents declare eligible Runner callables with an explicit target.
`plugins["rho.codemode"].configuration.default` controls exposure in new
rho-authored turns while accepted programs remain executable. The installer packages it in
every profile. It embeds V8 through the locked `mini_racer` gem and needs no Node, Bun or
Deno process. See the [JavaScript tool guide](../agents/rho/rho-codemode/README.md).

Core settings and plugin selections live in `$RHO_HOME/settings.json` (mode
`0600`). Existing credential-bearing files must belong to the runtime UID and
have no group/other permissions; reads and writes refuse widened permissions.
Inspect an exposure and explicitly restore `chmod 600` before retrying.
Each `plugins` entry owns its `enabled` choice, `configuration_version`
and `configuration`; installed packages provide their static settings schema.
`rho settings` and `rho extensions` remain available even when every optional
plugin is disabled. Native plugin state is kept under `$RHO_HOME/plugins/<id>`;
back up the complete rho home together with its credentials.

This directory is the installer's home — outside `agents/rho/rho`, because the installer is one
product's deployment story, not gem contents. Maintain the shell sources in
`install/src/{header,bootstrap,packages,launchers,lifecycle}.sh` and run
`rake install:render` from `agents/rho/rho`. The rendered `install/install.sh`
remains one standalone distribution; `install:check` rejects drift in either
source fragments or the manifest.

## What lands where

No sudo, ever. The prefix is yours; `~/.local/bin/rho` and `~/.local/bin/cmctl`
point into the same portable runtime and locked bundle.

```
$RHO_PREFIX/                       ~/.local/share/rho ($XDG_DATA_HOME/rho); the wrapper exports it
  bin/cmctl                        the operator CLI, using the same Ruby and bundle
  bin/rho                          the wrapper: portable Ruby + `-rbundler/setup` + exe/rho, no `bundle exec`
  bin/rg bin/fd                    runner, full, dev            (the grep and find tools' hard needs)
  bin/jq bin/uv bin/uvx            full, dev
  bin/rho-playwright               dev: Node + playwright-core, the browsers dir scoped inside this script
  bin/python3                      full, dev — ONLY when the host had no python3 (a uv shim)
  ruby/4.0.7/  ruby/current        Homebrew's portable Ruby bottle, Homebrew's layout; the lock's bundler inside
  versions/<app>-checkout-r<ruby>/ the packaged gem trees + vendor/bundle (bundle install --deployment --prefer-local); `.ruby` = the pair, `.commit` = the checkout's HEAD
  current -> versions/…            with `ruby/current`, always moved together (update, rollback)
  lib/playwright/{node,package}/   dev: Node 24 (never on PATH) and playwright-core at the gem's version
  browsers/                        dev: the Chromium headless shell (PLAYWRIGHT_BROWSERS_PATH, inside bin/rho-playwright only)
  cache/downloads/                 the verified downloads (RHO_DOWNLOAD_CACHE moves it); safe to rm -rf
  libexec/install.sh               this script's copy: `rho update`, `rho uninstall` exec it
  libexec/docker-entrypoint        the image's one door (copied when it sits beside install.sh)
  manifest.json                    the manifest this install came from
  receipt.json  receipt.sh         what was installed — the same facts, for rho and for bash
  .install.lock                    a mkdir lock while the script runs (stale after 600 s)
~/.local/bin/rho -> $RHO_PREFIX/bin/rho
~/.local/bin/cmctl -> $RHO_PREFIX/bin/cmctl
$RHO_HOME (~/.rho)                 rho state; setup writes selected settings and private credentials
```

The profiles are row sets, not modes: `runner` (Ruby, gems, rg, fd), `full` (+ jq, uv; the default),
`dev` (+ Node, playwright-core and the Chromium shell; enable them with
`rho extensions enable rho.browser`). A runner-profile
install can still run `RHO_MODE=full`; its models simply have no uv.

## Knobs

Environment or flag; the flag wins.

| Variable / flag | Default | Meaning |
|---|---|---|
| `RHO_PROFILE` / `--profile` | the receipt's, else `full` | `runner` \| `full` \| `dev` |
| `RHO_PREFIX` / `--prefix` | `~/.local/share/rho` | the toolchain's home |
| `RHO_HOME` | `~/.rho` | rho state; prewarm creates its cache, interactive setup writes chosen settings |
| `RHO_SOURCE` / `--from-checkout DIR` | the checkout this script sits in | the checkout to install the packaged trees from (the image builds with it explicit) |
| `NONINTERACTIVE` / `CI` / `--non-interactive` | unset | skip confirmation and setup; implied by a non-TTY stdin |
| `RHO_MODIFY_PATH=1` / `--modify-path` | unset | write the PATH line to the rc file; by default it is **printed** |
| `RHO_ARTIFACT_DOMAIN` | unset | a mirror tried before every URL: the same path under your domain |
| `RHO_NO_BOOTSNAP` | unset | skip the prewarm and, at run time, the cache |
| `RHO_BOOTSNAP_CACHE_DIR` | unset | baked into the wrapper (the image points it at its layer) |
| `RHO_LAUNCHER_DIR` | `~/.local/bin` | where the launcher goes |
| `RHO_DOWNLOAD_CACHE` | `<prefix>/cache/downloads` | where the verified downloads live |
| `--dry-run` | — | the plan and the exact URLs; nothing changes |

## The steps, end to end

guards (bash, not POSIX mode, not root outside a container, darwin/linux × arm64/x64, macOS ≥ 11,
glibc ≥ 2.17 and not musl) → prerequisites checked, never installed (`git` ≥ 2.7, `/bin/bash`,
`curl`|`wget`, `tar`, a sha256 tool, `cc` + `c++` + `make` — the apt/Xcode line is printed) → the plan, RETURN →
the lock → the portable Ruby (fetched from ghcr by its sha, unpacked, smoke-tested) → the lock's bundler
`gem install`ed into it, always (the locks say 4.0.22; without this, a different bottle default lets
`bundle install` fetch it silently and `-rbundler/setup` run on the wrong one) → the gems: the packaged
trees copied out of the checkout, `bundle install --deployment --prefer-local --without development test`
(`--prefer-local`: a default gem the lock pins at the portable Ruby's own version — openssl above all —
is used from the Ruby, never fetched and built beside its static OpenSSL, where conflicting symbols can break TLS), seeded from the
previous version's `vendor/bundle` when it was built against the same Ruby, then `current` and
`ruby/current` swapped together → the profile's tool rows (skipped when the receipt's sha equals the
manifest's and the file is there) → the wrapper (the host's CA bundle baked as `SSL_CERT_FILE` when the
portable OpenSSL's compiled cert path is absent), the shims, the launcher, the PATH line → the receipts →
the prewarm (`rho version`, `rho help`: the bootsnap cold boot lands here) → `rho doctor` → the epilogue.
A first interactive install then runs `rho setup`; unattended installs and updates
print recovery guidance. Setup asks for your Nexus URL, preserves saved choices
and does not start a daemon or make a paid model call. See
[setup and recovery](../docs/getting-started.md#rerun-or-recover).

The `current` swap is `ln -s target current.tmp` + `mv -Tf` (GNU) / `mv -hf` (BSD), probed — a plain
`mv -f new current` moves the new link *into* the directory on both mv's (`install/test/swap_test.sh`
proves the premise on the machine it runs on).

## Verification, in four classes

- **manifest-pinned sha256**: the portable Ruby (the sha is the ghcr blob address), rg, fd, jq, uv, Node,
  playwright-core.
- **manager-verified**: the gems, by bundler's `CHECKSUMS` in `Gemfile.lock`.
- **git**: the app itself — the checkout's `HEAD`, recorded in the receipt as `app.commit` (and in the
  version dir's `.commit`); `rho update` moves it by `git pull --ff-only` over whatever remote and
  transport the checkout has, and prints the range it moved.
- **HTTPS-only, named**: the Chromium headless shell (playwright-core's downloader verifies no hash).

Everything else the script says or does is in the script; every command is echoed before it runs.

## The wrapper's environment

Set for rho's own process, and therefore inherited by every tool child (`ChildEnv` restores the
wrapper's environment minus `BUNDLE_*`, `RUBYOPT`, `RUBYLIB`, `GEM_HOME`, `GEM_PATH`):

- `RHO_PREFIX` — the prefix; it joins `Rho.protected_roots`, so the incubation deny rules cover the
  wrapper, the portable Ruby, `vendor/bundle` and `libexec/install.sh`.
- `PATH` — `$RHO_PREFIX/bin` prepended: rg, fd, jq, uv, uvx (and the python3 shim) **shadow the person's
  copies inside the model's shell**. That is the point (the model's `rg` is the manifest's) and it is
  shadowing; `node` is deliberately not in `bin/`, so a project's Node is untouched.
- `LANG=C.UTF-8` — only when none of `LC_ALL`, `LC_CTYPE`, `LANG` is set (`Rho::Locale`'s rule, applied
  before Ruby tags `ARGV`).
- `RHO_BOOTSNAP_CACHE_DIR` — the baked value, else `$RHO_HOME/cache/bootsnap` at run time.
- `BUNDLE_GEMFILE`, `BUNDLE_PATH`, `BUNDLE_DEPLOYMENT`, `BUNDLE_WITHOUT` — Ruby's spelling of "load the
  app from the prefix".
- `SSL_CERT_FILE` — the host's CA bundle (`/etc/ssl/certs/ca-certificates.crt` on Debian and Ubuntu,
  `/etc/pki/tls/certs/ca-bundle.crt` on RHEL, `/etc/ssl/cert.pem` on a Mac; the manifest's `wrapper_env`
  lists the probe), baked only when the portable Ruby's static OpenSSL points at its builder's absent
  cert path — without it every Ruby-side HTTPS fails `certificate verify failed` (the box finding 2026-09-16). A value already in the environment wins; every tool child inherits it.

**Not exported** (r2): `RHO_BROWSER_PLAYWRIGHT_CLI`, `PLAYWRIGHT_BROWSERS_PATH`, `UV_*`. The browser
extension finds `$RHO_PREFIX/bin/rho-playwright` at its own spawn site (`Rho::Browser::Driver.default_cli`);
that script scopes the browsers dir to itself and its Chromium; uv is unconfigured, so its Pythons land in
uv's own default directory, shared with the person's uv. A project's own `npx playwright` never sees rho's
browsers.

## The verbs

- `rho doctor [--strict]` — a rho verb (its rows are rho's own facts: the receipt, the lock's bundler
  against the one that loaded, the (ruby, gems) pair, the TLS trust store — the file OpenSSL reads its
  roots from, shown to be trusted by the default store offline, and the openssl extension the portable
  Ruby's own — the gem's Playwright pin, the home, the daemon).
  `lib/rho/doctor/*.rb`, one check module per row kind. `--strict` exits 1 on any red row (the image's
  build-time check, the e2e install lane).
- `rho update [--dry-run] [--rollback] [--restart] [--profile P] [--add-rows] [--modify-path]` — a thin
  verb that execs `libexec/install.sh --update`. The ladder, in order: no receipt → refused; inside a
  container → refused (the image rolls: `docker compose pull && docker compose up -d`); the receipt's
  source path gone or not a git checkout → refused, the clone-and-install line printed; an unfinished git
  operation there (`MERGE_HEAD`, `rebase-merge`, `rebase-apply`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
  `sequencer`, `BISECT_LOG`) → refused; then `GIT_TERMINAL_PROMPT=0 git pull --ff-only` in the checkout
  (a dirty-but-non-conflicting tree is git's call, a diverged branch is yours, a checkout with no remote
  gets git's own line) → **two prints** — the commit range pulled (`old..new` as `git log --oneline`) and
  the script that runs next — → `exec` of THE CHECKOUT's `install/install.sh --apply-update
  --from-checkout <path> --profile <p> --non-interactive`: the pulled script is the new truth, its
  embedded manifest the rows. Rows whose sha changed are installed, the rest skipped; the app is
  restaged when the commit moved (a no-op pull re-bundles nothing); a Ruby change rebuilds the bundle
  into a new `versions/<app>-checkout-r<ruby>`; the previous pair stays for `--rollback`, which moves
  `current` and `ruby/current` back together (`app.commit` follows, from the dir's `.commit`).
  `--dry-run` fetches instead of pulling, shows the two prints and runs nothing. `--restart` stops the
  announced daemon (TERM) and prints the start line — `rho server` is a foreground process with no
  supervisor of rho's, so that is the only definable restart. No background auto-update and no update
  check on a verb. A checkout run under `bundle exec` (no `RHO_PREFIX`) is refused: that
  checkout is the developer's own `git pull`, installed by running `install/install.sh` again.
- `rho uninstall [--purge]` — removes the launcher, the exact rc line it wrote, the prefix; `--purge`
  disconnects first when the home is bound, then removes `RHO_HOME`. Refuses while a daemon is announced
  and alive (`--force` overrides).

Both `update` and `uninstall` exec a shell script because the installer logic lives in one file, as
`brew update` is shell.

## The manifest (`manifest.json`), the rendering, the bump

`manifest.json` is the manifest source. bash 3.2 parses no JSON, so `rake install:render` (from
`agents/rho/rho`) writes `manifest.sh` — every row as a shell variable — and assembles the fixed
`src/*.sh` fragments, that shell block and the verbatim JSON document into the standalone
`install.sh`. `rake install:check` (in rho's default rake task) rejects generated files that differ
from those sources. `rake install:bump` refreshes every row from its publisher
(network; never in CI): brew HEAD's four `portable-ruby-*` files, the GitHub release APIs of ripgrep /
fd / jq / uv (fd's tarballs and playwright-core's are hashed, the others copy the publisher's checksum
file), nodejs.org's index, the gem's `Playwright::COMPATIBLE_PLAYWRIGHT_VERSION`, playwright-core's own
apt table for the Chromium libraries, the image's mise and gh from their checksum files, and the image's
tool list pinned to full versions through this machine's `mise ls-remote` (`node@24` → `node@24.21.0`: a
reproducible image). It refuses a Ruby `rho.gemspec` cannot use. The app has no row to bump — its source
is the checkout and its version the commit.

The schema, language-neutral — another agent ships its own instance and walks the same algorithm
(detect the platform → check `prerequisites` → for `runtime` and each `tools` row in the profile: fetch,
verify, unpack under a user-owned prefix, record → unpack the app, install its dependencies with the
runtime → write a wrapper → link the launcher → prewarm → doctor):

| Key | Rows |
|---|---|
| `app` | `name`, `trees`, `entry`, `gemfile`, `bundle_without` — the last three are rho's Ruby-specific rows; the app's source is the checkout the installer sits in, its version the commit (the receipt's `app.version` is the gem's, `app.commit` the checkout's `HEAD`, `""` for an unpacked tree) |
| `runtime` | `kind`, `version`, `bundler` (Ruby-specific), `headers`, `artifacts.<platform> {tag, filename, url, sha256, bytes}` |
| `tools.<name>` | `version`, `profiles`, `into`, `unpack` (`members` \| `binary` \| `tree` \| `command`), `verification`, `artifacts.<platform \| all> {url, sha256, members}`; `command` for the Chromium row; `derived_from {value, provenance}` for the driver |
| `wrapper_env` | what the wrapper exports and, by name, what it does not |
| `prerequisites`, `apt`, `brew` | checked, printed, never run; `apt.chromium.<distro>` by name |
| `toolchains` | the image's project-toolchain layer (mise, uv's Pythons, gh, tini) — walked by the Dockerfile, never by the host installer |

The receipt is the manifest's rows plus `installed_at`, `profile`, `platform`, `source_path`, `current`,
`previous`, `launcher`, and per row the sha found; `receipt.sh` is the same for bash.

## The image

`install/docker/Dockerfile` runs this same script inside `ubuntu:26.04` (`--from-checkout`, profile
`full`, into `/opt/rho` as uid 1000). Docker Hub publishes the `browser` target. The
`toolchains` layer adds the project toolchains from the manifest's `toolchains`
rows (mise, uv) and the `browser` target adds Chromium's libraries from `apt.chromium.ubuntu26.04`
plus `--add-rows --profile dev`, Office converters, fonts and the locked Cowork Python environment.
The smaller targets remain available for custom builds. The image's usage guide is
`/usr/local/share/cybros/workspace-tools.md` ([source](docker/workspace-tools.md)).
rho's Coding extension exposes it as the optional `workspace-tools` skill, loaded on demand
through the existing `skill` tool. A project skill of the same name in the announced catalog
takes precedence; a host installation without the guide announces no extra skill.
The Dockerfile sources `manifest.sh` in its RUN steps and carries no
version of its own. `install/docker/README.md` (the build), `docs/rho-deploy.md` (running it),
`install/docker/compose.yml`, `install/docker-entrypoint` (tini's child; execs `bin/rho "$@"`).

## Rolling from the checkout

There is no release archive and no release tag: a person clones the repository and
runs `install/install.sh` from it; `rho update` is `git pull --ff-only` in that clone followed by the
pulled `install/install.sh --apply-update`. The receipt's `source_path` names the clone, `app.commit`
its `HEAD`. Rollback is the (ruby, gems) pair kept as `versions/<app>-checkout-r<ruby>.old` — exactly one
previous — and, for the code itself, the clone's own history. The combined Docker stack instead
updates its two images together with `./cybros update`
([stack guide](stack/README.md)); `rho update` inside a container refuses and says so.

## Tests

`rake install:test` (or `install/test/run.sh`): shellcheck on every script, then `guards_test.sh` (the
shell, POSIX mode, the flags, the profile, an unsupported platform, `--dry-run`), `render_test.sh` (the
render/check pair on a copy), `download_test.sh` (interrupted downloads resume, mirror fallback,
range rejection and checksum verification, offline), `swap_test.sh` (the symlink swap on a temp dir,
and the plain-`mv -f` premise), `seed_test.sh` (the seed copies a same-Ruby previous `vendor/bundle` and leaves the original
untouched; another Ruby seeds nothing, offline), `stage_test.sh` (stages the real package trees and
checks cmctl and the shipped extension resources arrive unchanged, offline),
`launcher_test.sh` (executes rho/cmctl wrappers with a recording portable runtime,
checking shared bundle, argument boundaries and environment isolation),
`install_test.sh` (a checkout install into `mktemp -d` prefixes with a temporary home and
launcher dir, the checkout a clone of a bare upstream seeded from this working tree: `rho version`,
`rho doctor --strict`, a second run that keeps the previous version, a rollback, then the update lane —
one upstream commit, `rho update --dry-run` (the two prints, nothing run), `rho update` (pulled,
`app.commit` moved, `current` re-pointed, `.old` kept), a second `rho update` with nothing new, the
rollback, the in-progress-operation refusal, the no-remote answer — then `--modify-path`,
`rho uninstall`, `--purge`), `update_test.sh` (the same ladder and dry run OFFLINE against a fabricated
receipt: no Ruby, no gems — CI's half of the update), `docker_test.sh` (the image: `base` and
`rho` built for the host's arch, the verbs through the door, `doctor --strict` inside, tini reaping an
orphan, the packaged WebUI served in full/agent mode and absent in runner/api-only mode, the compose
file; opt-in with `RHO_INSTALL_TEST_DOCKER=1`). The install test needs the network —
`RHO_INSTALL_TEST_CACHE=<dir>` keeps the ~35 MB of downloads between runs; `RHO_INSTALL_TEST_OFFLINE=1`
skips it (CI's `agent_rho` job runs the offline set).

## Prerequisites the script prints and never installs

macOS ≥ 11: the Xcode Command Line Tools (`xcode-select --install`: git, cc, c++, make). Linux (glibc ≥ 2.17,
2.28 for the dev profile's Node; no musl — the image covers Alpine): `apt-get install bash
ca-certificates curl git build-essential xz-utils`, and for the dev profile's Chromium the shared
libraries by name (`apt.chromium.<distro>`; printed after the install; `rho doctor` reports them missing).
Nexus generates upload thumbnails and previews in its own process: libvips resizes images,
Poppler's `pdftoppm` renders PDF pages, and `ffmpeg` renders video frames. Install these in the
Nexus environment; see [Nexus file previews](../nexus/README.md#file-previews) for packages and
`uploads:check_preview_dependencies`. The rho image carries Poppler and FFmpeg for local tools,
but a separate Nexus cannot use those binaries. `rho doctor`'s `previewers` row checks only
rho's environment. A Nexus without an applicable previewer answers `representation_unavailable`
for that preview read; the original upload bytes remain readable.
C and C++ compilers are needed because io-event, json, bigdecimal, msgpack, bootsnap and
mini_racer are built against the portable Ruby on this machine. V8 itself is supplied
by the locked precompiled `libv8-node` package. openssl is the portable Ruby's own: `bundle install --prefer-local` uses the
bottle's default gem at the lock's pin, where a plain `bundle install` fetched and built a second copy into
`vendor/bundle` beside the bottle's static OpenSSL — one that could not verify a certificate on Linux
(the box finding 2026-09-16). The apt line still names `libssl-dev` and `pkg-config`: they
serve only a lock whose openssl pin outruns the bottle's, and `rho doctor`'s tls row refuses that build.
nokogiri (rho-web-tools' HTML parser) ships precompiled for the manifest's four platforms — the lock carries
them — so it asks for no compiler and no libxml2 headers.

A tarball or `install.sh` saved through a browser or Finder carries `com.apple.quarantine`; `curl` sets
none. `xattr -d com.apple.quarantine <file>` is the recovery.
