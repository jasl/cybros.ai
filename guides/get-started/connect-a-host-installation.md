# Connect a host installation

Run rho directly on a workstation or server and connect it to an existing Nexus — the stack's Nexus on another machine, or a standalone deployment.

## Install rho on the host

Clone the public repository and run the host installer. It installs a portable Ruby and the packaged gems into a user-owned prefix and prints launcher and `PATH` instructions. Linux with glibc and macOS are supported on x64 and arm64.

```sh
git clone https://github.com/jasl/cybros.ai.git
cd cybros.ai
bash install/install.sh
```

The default `full` profile includes the browser page. The `dev` profile adds Playwright and Chromium for the model's optional browser tools. The installer prints prerequisites it does not install, such as a compiler and download tools.

## Pair and configure

In an interactive terminal, replacing the example address:

```sh
rho setup --nexus-url https://nexus.example
```

The wizard lets you create an account in Nexus if needed, approve the device code, configure Telegram, optionally configure a provider through the same human OAuth login, and choose a saved default model. rho saves this terminal login for later setup commands.

To connect without the setup wizard, use `rho connect` instead. For Nexus running
on the same Mac or Linux host at port 3000:

```sh
rho connect --nexus-url http://127.0.0.1:3000
```

Complete the displayed browser or device-code approval and wait for the terminal
to print **Connected** or **Connected as …**. Starting the daemon alone does not
connect it. `rho connect` establishes credentials; choose a model separately
before your first request.

Keep the same `RHO_HOME` in every terminal (default `~/.rho`). Later commands use
its saved Nexus address. HTTP `localhost` and `127.0.0.1` share a binding; see
[Command line](../reference/cli.md) for the address rules. If connection fails,
use [Troubleshooting](../use/troubleshooting.md#host-connection-and-first-request).

rho announces a Local Runner service on the application address, reserved for its Main Agent, Bots and Subagents. Independent executor implementations can serve several applications under their approved [sharing scope](../runners/deploy.md#identity-and-scope).

## Connect with API keys

In Nexus **Agents**, create an Agent and issue its member and application keys.
rho uses these same two keys for its agent and Runner services.
Copy each value when it is shown; Nexus cannot reveal it again.

```sh
rho connect --api-key --nexus-url https://nexus.example
```

The prompts hide the keys. For automation, `--api-key-stdin` accepts the JSON
fields documented in [Command line](../reference/cli.md). rho verifies that the
application belongs to the selected Agent, saves the keys
privately, and uses them directly on every request. No device approval or token
refresh is needed for this connection.

Human settings remain separate. A later Nexus sign-in grants Human authority
without replacing the running Agent or Runner keys. `rho disconnect` revokes
the installed keys; issuing a replacement key in Nexus does not revoke an older
key until you explicitly do so.

## Run it

Start the foreground server in one terminal and use another under the same rho home. A running service applies saved settings immediately.

```sh
# Terminal 1
rho server

# Terminal 2
rho status
rho models --workload text_generation
rho console --open
```

`rho console --open` opens rho's public URL. Choose **Connect to Nexus** or **Use a device code** to establish the browser session, then create a conversation with an available model and runner. The runner uses its default working directory.

Check `rho status` for the connection state as well as the running daemon. If
the state is disconnected or not connected, finish `rho connect` before sending
a request. A pending workspace alone is not evidence of a completed connection.

Choose a `provider/model` identifier from `rho models --workload text_generation`.
Replace `provider/model` below with that exact identifier for a quick text check:

```sh
rho run "Say hello" --model provider/model
```

To save that choice for future requests:

```sh
rho settings '{"default_model":"provider/model"}'
rho run "Say hello"
```

Saved settings apply immediately to the running daemon. Model discovery does
not make a model request; `rho run` is a normal, potentially billed request.
If no usable model is listed, configure one through
[Models and providers](../operate/models-and-providers.md), then list models again.

## Keep it running

`rho server` stays in the foreground. For a persistent service, let your deployment's service manager own start, stop and restart. Never start a second daemon on the same rho home.

Full details — binding to other addresses, transport assertions, environment variables and separate rho containers — are in [Deployment layouts](../operate/deployment-layouts.md).
