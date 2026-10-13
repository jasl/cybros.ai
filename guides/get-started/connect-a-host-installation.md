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

The wizard lets you create an account in Nexus if needed, approve the device code, configure Telegram, optionally configure a provider through the same human OAuth login, and choose a saved default model. rho saves this terminal login for later setup commands. `rho setup` is available in full and agent modes; a runner-only installation uses `rho connect` instead and hosts no conversation UI.

Full mode pairs a bundled Runner reserved for that rho instance, including its eligible Bots and Subagent work. A runner-only installation can instead serve several Agents; its manager approves the [sharing scope](../runners/deploy.md#identity-and-scope) during pairing.

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

Full details — modes, binding to other addresses, transport assertions, environment variables and the separate runner container — are in [Deployment layouts](../operate/deployment-layouts.md).
