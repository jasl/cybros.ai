# Runner quickstart

Every stack installation already has a Runner reserved for that rho instance: full mode runs the Agent and its Runner in one process, with `/home/runner` (the installation's `data/rho/work`) as its working directory. This page adds an independent Runner on another machine so eligible Agents can work on that machine's files.

## 1. Start a runner on the other machine

Use the published image. Replace the Nexus address with the one the other machine can reach, and mount the project you want the agent to work on:

```sh
docker run -d --name rho-runner --restart unless-stopped --stop-timeout 30 \
  -e RHO_NEXUS_URL=https://nexus.example \
  -e RHO_DISPLAY_NAME="project runner" \
  -v rho-runner-home:/var/lib/rho \
  -v "$PWD:$PWD" -w "$PWD" -e RHO_TOOLS_ROOT="$PWD" \
  docker.io/jasl123/cybros-rho:latest
```

Or install rho on that host and start it in runner mode:

```sh
rho server --mode runner
```

The runner needs outbound access to Nexus and publishes no port.

## 2. Pair it

```sh
docker exec rho-runner rho connect     # container
rho connect                            # host
```

`connect` prints a device code and a verification link. Open the link as the Human who will manage the Runner, check the code and approve. This independent Runner uses `user_private`, so all Agents you steward may use it; an owner or administrator can opt a fresh registration into `account_wide` on the approval page. The Runner receives only a transport credential. rho's bundled Runner uses the narrower `agent_private` scope; see [Identity and scope](deploy.md#identity-and-scope).

```sh
docker exec rho-runner rho status
```

## 3. Select it

From the agent's installation, list eligible runners and choose the new one for future conversations:

```sh
rho runners
rho runners use RUNNER_ID
```

Or choose it in the browser when creating a conversation. The default applies to new conversations; an existing conversation keeps its runner, and explicit tool declarations can still target any eligible runner.

## 4. Verify

Start a conversation on the new runner with its working directory and ask:

> Which machine are you on? Write the output of `uname -a` to hello.txt in your working directory.

Read `hello.txt` on the runner's host. The kernel addressed the call to that runner's inbox, the runner claimed and executed it locally and committed the result; the browser never connected to the runner.

## Next

- [Deploy a runner](deploy.md) for service management, state, LAN binds and updates
- [Tools and announcements](tools-and-announcements.md) to see what the runner declared
- [Security model](security-model.md) before giving a runner access to anything sensitive
