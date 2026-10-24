# Runner quickstart

rho includes a Local execution environment on its application address. In the stack,
its working directory is `/home/runner`, backed by `data/rho/work`. On a host,
tools run as the user who starts rho.

## 1. Connect rho

For the stack, open its rho page and complete **Connect to Nexus**. On a host:

```sh
rho setup --nexus-url https://nexus.example
rho server
```

The application announces both Agent and Runner services on one Executor. Local is
available to this rho's Main Agent, Bots and Subagents when their execution policy
permits it. Another rho cannot use this Local environment, even under the same Human.

## 2. Choose a working directory

Use the working-directory picker when creating a conversation, or start one from
the CLI:

```sh
rho run 'Create hello.txt containing hello' --dir /absolute/path/to/project
```

For a container, mount the project at the directory used inside the container and
give UID 1000 the permissions needed for the work. A working directory is not a
filesystem sandbox.

## 3. Verify execution

Read `hello.txt` in the selected directory. Nexus accepts and addresses the tool
call; rho claims it on the executor plane, writes the file and commits its result.
The browser does not need a direct connection to an independent executor.

## Use an independent Runner

Nexus supports independent Runners through the public executor protocol. There is
currently no separately deployable first-party Runner application; the rho image
and `rho server` both run the complete rho application. `rho-env` is an embeddable
Ruby execution library, not a standalone service.

To share an environment across applications, deploy your own executor implementation
and complete its device connection. Its Human manager grants `user_private` scope;
an owner or administrator may choose `account_wide` for a fresh registration.
Then select its UUID from rho:

```sh
rho runners
rho runners use RUNNER_ID
```

The saved choice affects new conversations. Accepted tasks retain their original
targets, and selecting an environment never transfers files.

## Next

- [Deploy a runner](deploy.md) for environment deployment and assignment scope
- [Tools and announcements](tools-and-announcements.md) for the executor contract
- [Claims and results](claims-and-results.md) for implementing a worker
