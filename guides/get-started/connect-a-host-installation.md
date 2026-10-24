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

For a quick noninteractive text check with a saved default model:

```sh
rho run "Say hello"
```

This is a normal, potentially billed model request.

## Keep it running

`rho server` stays in the foreground. For a persistent service, let your deployment's service manager own start, stop and restart. Never start a second daemon on the same rho home.

Full details — binding to other addresses, transport assertions, environment variables and separate rho containers — are in [Deployment layouts](../operate/deployment-layouts.md).
