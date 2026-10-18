# Run a standalone SDK Agent

Run the TypeScript example to connect your own Agent, submit an Input, serve an
application tool and save its output. You can exit after submission and recover
the same execution in a new process. It uses public Nexus APIs through
`@cybros/agent` and needs no rho process or separate Runner.

## Prepare the example

Use a running Nexus, a Human who can approve the connection, and an available
text model. From the repository's `sdks/typescript` directory, use Node 22.13+ or
Node 24 and the pnpm version declared in `package.json`:

```sh
pnpm install --frozen-lockfile
pnpm run build
pnpm exec tsx examples/standalone-agent.ts --help
```

This runs the example from the source checkout. The SDK is a source package;
these commands do not depend on a registry release. The source is
[`examples/standalone-agent.ts`](https://github.com/jasl/cybros.ai/blob/main/sdks/typescript/examples/standalone-agent.ts).

Choose the Nexus URL and a private credential location:

```sh
nexus_url='http://127.0.0.1:3000'
agent_credentials="$PWD/.standalone-agent/credentials.json"
```

The program creates the private directory and credential file. Keep that path
out of source control. One CLI process owns it at a time.

## Connect the Agent

Choose a stable identifier for this installation:

```sh
pnpm exec tsx examples/standalone-agent.ts connect \
  --url "$nexus_url" --credentials "$agent_credentials" \
  --agent-identifier 'example.my-installation'
```

Open the printed `verification_uri_complete`, sign in as the Human steward and
approve the connection. The command saves rotating member and application
executor credentials and prints their public Agent and Executor UUIDs.

Use `start` or `resume` with an existing credential file. `connect` refuses to
replace it. See [Credentials and planes](credentials-and-planes.md) for the
authority each credential carries.

## Submit and finish

Replace `local/example` with a model available on your Nexus:

```sh
pnpm exec tsx examples/standalone-agent.ts start \
  --url "$nexus_url" --credentials "$agent_credentials" \
  --model 'local/example' --text 'Describe one useful way to organize a project.' \
  --output-dir "$PWD/standalone-output"
```

The example declares a concise prompt and one `capture_text` application tool,
announces that tool, creates a Workspace and Conversation, and submits a
direct-reply Input with a trailing capture step. Nexus runs the model work.
The application claims its tool, uploads the supplied text and commits a
`resource_link` result.

On completion, the application reads the committed attachment through the member
API and saves two files:

| File | Content |
| --- | --- |
| `capture.txt` | The submitted text, exactly as UTF-8 bytes |
| `conversation.jsonl.gz` | The [Conversation diagnostic export](../reference/agent-api/conversation-export.md) |

Output is streamed into temporary files and published after successful receipt.
The export also passes gzip and completion-record validation. A later successful
download to the same output directory replaces those two files.

## Exit and recover

To demonstrate recovery, start another execution with `--submit-only`:

```sh
pnpm exec tsx examples/standalone-agent.ts start \
  --url "$nexus_url" --credentials "$agent_credentials" \
  --model 'local/example' --text 'Give me a short project checklist.' \
  --submit-only
```

The command prints an `accepted` JSON record containing `workspace_public_id`,
`conversation_public_id` and `input_public_id`, then exits. Keep those three
values. Nexus can advance the model work while the application is stopped;
the application tool waits for its executor to return.

Use the printed UUIDs to resume:

```sh
pnpm exec tsx examples/standalone-agent.ts resume \
  --url "$nexus_url" --credentials "$agent_credentials" \
  --workspace 'WORKSPACE_UUID' --conversation 'CONVERSATION_UUID' \
  --input 'INPUT_UUID' --output-dir "$PWD/recovered-output"
```

Recovery follows that accepted Input's original execution and automatic fallback
lineage. It does not submit another Input. A completed execution can be resumed
again to download its existing result; the tool is not executed again.

## Runtime limits

The default command timeout is five minutes; set `--timeout-ms` to choose another
finite wait. The example polls HTTP and serves only its known tool in the selected
execution. It reports blocked inputs, paused Runs and work needing attention so
you can inspect them through the ordinary APIs.

Ctrl-C or a local timeout ends observation. Accepted work remains in Nexus;
[stopping a Run](../reference/agent-api/runs.md) is a separate explicit operation.
If a process dies after claiming a tool, this example does not recover its lost
claim token or automatically repeat an ambiguous commit. The existing claim
deadline and result protocol apply.

Credentials are atomically replaced during rotation and remain local bootstrap
state. Shutdown drains an already-started credential exchange and publication;
canceling the local wait does not discard credentials already issued by Nexus.
Execution state stays in Nexus. A hard crash can leave a sibling `.lock`
file: remove it only after confirming that no process still uses the credential
path. The example does not automatically reclaim locks.

## Next

- [TypeScript SDK](sdk-typescript.md) for the reusable resource APIs.
- [Claims and results](../runners/claims-and-results.md) for a long-running executor.
- [Offline application](offline-agents.md) for work that can continue without its application.
