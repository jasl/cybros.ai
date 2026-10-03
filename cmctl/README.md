# cmctl

cmctl is the Human operator command line for Nexus. It uses `cybros_agent`'s
Platform client to configure provider connections, model definitions and
credentials. The deployment catalog remains the base. It runs on Ruby 4.0 on Linux and macOS; it needs no
JavaScript runtime.

## Run from source

```sh
cd cmctl
bundle install
bundle exec cmctl help
```

The project uses the adjacent `sdks/ruby` checkout. `bundle exec rake` runs
the command and persistence tests plus RuboCop; `bundle exec rake build`
packages the executable as a gem. Installing the gem adds `cmctl` to PATH.

## Configure a deployment

For guided terminal setup, after creating the first account in Nexus:

```sh
cmctl setup --url http://localhost:3000
```

The same wizard is included in `rho setup` and the Compose installer's
`./cybros setup`. It signs in as a Human owner/admin for this command only,
preserves the separate saved cmctl login, and revokes its own API session on
success, cancellation or failure. If Nexus cannot be reached for revocation,
it reports that explicitly; review the API session under Nexus Settings → Sessions.
Passwords, provider API keys and the setup login are not saved locally.

Select a provider or add a custom connection. Keep, replace or clear an existing
API key, or follow the Codex subscription's browser URL and code. Re-running
setup resumes a pending login; replacing another administrator's login requires
an explicit choice. Ctrl-C stops waiting without erasing completed settings.
OAuth credentials are issued to and stored by Nexus, never imported from a Codex
CLI installation. Models can be discovered from the provider's directory or
entered manually, including when discovery fails. Configure context/output
limits and tool support for the chosen model. Prices are optional; without
prices, an unset Account cost unit does not block setup or execution.

Setup requires a terminal and does not run paid inference. Choose a default model
in `rho setup model`, then send a first conversation to verify actual execution.
The commands below remain available for scripting and individual changes.

Start Nexus and finish its browser-based first setup to create the Account
and owner. Then log in as that owner or an active Human administrator:

```sh
bundle exec cmctl login --url http://localhost:3000 --email operator@example.com
bundle exec cmctl status
bundle exec cmctl providers
bundle exec cmctl models --workload text_generation
```

Login prompts for the password without echo. A temporary password must first
be changed in the Nexus browser console. Login saves only the API Session
and server URL, in `~/.cmctl/session.json` with file mode `0600` beneath a
`0700` directory. `CMCTL_HOME` or a leading `--home DIR` chooses another
connection; each home holds one login. Logout before replacing it.

If the Account has no cost unit, choose one explicitly when enabling monetary
estimates. Ordinary browser setup already configures USD. The unit must match the
pricing in the server catalog. The value can be
configured once; repeating the same value succeeds, while a different value
is a conflict. The non-interactive command supplies no default:

```sh
bundle exec cmctl account cost-unit USD
bundle exec cmctl provider key set openai_api
bundle exec cmctl provider enable openai_api
bundle exec cmctl models --available --workload text_generation
```

`provider key set` prompts for the key without echo. It also rotates an
existing API key. The key is sent to Nexus and never saved by cmctl or
printed back. Installation and enablement are separate operations. Enable
and disable read the current provider version before writing; a concurrent
change returns `stale_object`, and the command does not retry it blindly.

`models` returns the full administrative catalog, including unavailable models,
with each model's reference, capabilities, pricing and availability
reason. Availability is a configuration/admission check, not a network test:
an installed key may still be rejected by its provider. Verify actual model
execution through a normally connected rho:

```sh
rho models --workload text_generation
rho run --model MODEL_REF 'Reply with a short greeting.'
```

Replace `MODEL_REF` with a reference returned by the list. The explicit
`rho run` sends a real request and may incur the selected provider's normal
charge. cmctl does not run models or borrow rho's member credential.
Every Agent's model discovery returns the account's available models; only
the administrative `cmctl models` listing has an `--available` filter.

## Custom connections and model definitions

These commands save through Nexus and take effect for subsequent requests
without editing files or restarting services:

```sh
cmctl provider add local --base-url http://127.0.0.1:11434/v1 \
  --api-format openai_compatible_chat --credentials none --display-name "Local models"
cmctl provider discover local
cmctl model add local/my-model --input-tokens 32768 --output-tokens 8192 --tools
cmctl provider enable local
cmctl provider show local
```

Use the upstream ID after `local/`, or set `--model-id ID` when the catalog
reference should be an alias. Directory discovery only lists IDs, makes no
inference call, and does not infer model capabilities or prices. `model add`
always accepts a manually supplied ID. Configure API keys through the existing
`provider key set` command when `--credentials api_key` is selected.

`provider edit ID` accepts the same connection flags and preserves omitted
fields. `model edit REF` accepts the model flags and likewise preserves other
definition fields. Optional `--input-price` and `--output-price` are decimal
amounts per million tokens in the Account's unit. Use `--price-unit UNIT` when
the Account has no unit, or `--clear-pricing` to remove the model's estimate.
Explicit zero rates are allowed. No price is required to run a model, and
unknown monetary amounts remain absent while usage quantities are recorded.

`model remove REF` removes a model from the effective catalog; `model reset REF`
restores its deployment definition, or removes the override if no base exists.
`provider reset ID` restores a deployment connection; for a custom provider it
removes that definition and disables the retained policy. It preserves keys.
Use `provider disable ID` instead to preserve all configuration for later use.
All definition writes use the provider's current version and return a conflict
without retrying over another administrator's changes.

To hide one model while preserving its definition and pricing:

```sh
bundle exec cmctl model hide openrouter/vendor/model
bundle exec cmctl model unhide openrouter/vendor/model
```

Hiding removes the model from Agent discovery and refuses new calls. The full
`cmctl models` listing keeps it with `visible: false` and `available: false`.
Its reason is `model_hidden` when the provider is enabled; a disabled provider
reports `provider_disabled` first. Unhide restores visibility; a disabled
provider or missing key still prevents use. Both commands read the provider
policy's version and return its updated lane. A concurrent edit returns
`stale_object` without a retry. They do not enable the provider: an untouched
provider with no policy returns `not_found`; an existing disabled policy can
still be edited.

## Automation and daily operation

Execution details are retained for 90 days by default. Administrators can read
or change that Account policy; `off` disables automatic collection:

```sh
bundle exec cmctl account retention
bundle exec cmctl account retention 180
bundle exec cmctl account retention off
```

The same setting is available in Nexus under Administration → Retention settings.
Collection removes eligible old execution details after work finishes while
keeping conversation text and its search history. Increasing the period does
not recover details already removed. Updates return the current Account setting
as JSON; no local configuration copy or retry is maintained.

All successful commands except help and the interactive setup write JSON to stdout. Failures write a
safe message and stable API error code, when available, to stderr. Exit codes
are `0` for success, `1` for a request/local failure, `2` for command usage,
and `130` for interruption. Commands make no automatic mutation retries.

For unattended use, supply one secret line through stdin explicitly:

```sh
bundle exec cmctl login --url https://nexus.example.com --email operator@example.com --password-stdin < /path/to/password-file
bundle exec cmctl provider key set openai_api --stdin < /path/to/provider-key-file
bundle exec cmctl provider disable openai_api
bundle exec cmctl provider key clear openai_api
bundle exec cmctl logout
```

Passwords and keys are never accepted as command-line arguments. Protect
input files using your existing secret-management tooling. Logout revokes
the API Session before removing it locally. An unreachable server leaves the
local session intact so revocation can be retried. `logout --local` explicitly
forgets it without remote revocation, for example after a server was removed.
Expired or already revoked sessions can be logged out normally.

## Scope

The deployment catalog supplies the base definitions and supported adapters.
This CLI configures provider connections, model definitions and optional prices
through Nexus's account overlay, and manages keys, visibility and provider OAuth.
It does not define executable adapters or administer users.
The [Platform model API](../docs/platform-api/v1/admin-models.md) describes
the server authority and error contract. Agents discover available models
through the member API; only Human operators configure them.
