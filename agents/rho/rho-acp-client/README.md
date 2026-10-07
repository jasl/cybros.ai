# rho-acp-client

rho as an ACP client, as an extension: another agent an operator names,
delegated to by the model through one tool, `delegate_agent`, with its
permission requests relayed to rho's own floor — and the management verbs
that list and probe the rows.

## One sentence, and what it rules out

A delegated ACP agent is a tool behind an executor. rho runs the client;
the kernel addresses `delegate_agent` to its announcer and judges and
settles the call exactly as it does `bash`. Nothing here changes Nexus or
the SDK: the whole gem is one schema-defined plugin configuration, the registry's seams, the verbs, `GET /acp`. The wire — the framing, the two-way connection, the method
names — is `rho-acp`'s, the agent gem this one depends on and speaks from
the other end; never a second implementation of the protocol. The
row-secrets rule and the child-env scrub are the runner's
(`Rho::Runner::Secrets`, `Redact`, `ChildEnv.scrubbed`).

The permission call_tool is a FLOOR, never a proxy: a child agent's request
runs through rho's own rules (`Guard.refusal`: the nine command shapes and
the protected roots) and then the row's policy; `allow_always` is never
answered, because a standing grant is the person's `rho rules`, not a click
the child forwarded.

## Wanted, not merely installed

```json
{
  "plugins": {
    "rho.acp-client": {
      "enabled": true
    }
  }
}
```

The distribution includes this plugin, disabled by default. Enable it in
Settings → Plugins or with `rho extensions enable rho.acp-client`; configuration
remains available while disabled. Changes are saved immediately; replacing its process-wide child sessions
requires restarting rho, which keeps current calls on their existing configuration.

## The rows — `plugins["rho.acp-client"].configuration.agents`

No row ships: a row is a launch command with a credential, which only the
person can write. The first row is Codex under the ChatGPT login, the second `opencode acp` on OpenRouter:

```json
{
  "plugins": {
    "rho.acp-client": {
      "configuration": {
        "agents": {
          "codex": {
            "command": "npx",
            "args": [
              "-y",
              "@agentclientprotocol/codex-acp@1.12.0"
            ],
            "env": {
              "CODEX_HOME": "/home/me/.rho/plugins/rho.acp-client/codex",
              "NO_BROWSER": "1",
              "INITIAL_AGENT_MODE": "read-only"
            },
            "description": "Codex under the ChatGPT login",
            "model": "gpt-6-astra"
          },
          "opencode": {
            "command": "opencode",
            "args": [
              "acp"
            ],
            "env": {
              "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}"
            },
            "description": "OpenCode, a coding agent on OpenRouter",
            "permissions": "allow",
            "timeout_ms": 600000,
            "auth_method": null,
            "model": null,
            "enabled": true
          }
        }
      }
    }
  }
}
```

The other registry lines: `npx -y @google/gemini-cli@0.59.0 --acp`, `npx -y
@agentclientprotocol/claude-agent-acp@0.78.0`.

Keys: `command args env description permissions timeout_ms auth_method model
enabled`. `${NAME}` in `env` expands once from the daemon's environment and
is a secret (an unset name is that row's fault); a literal under a
credential-shaped key is a secret too; every secret is erased from the
result, the progress lines, the capture and the log. `description` is
required: it is the person's words in the roster AND the model's text (the
tool invents no sentence in the agent's mouth). `permissions` is `allow`
(default) or `reject`; `timeout_ms` the one clock (default ten minutes);
`auth_method` an agent-type method id of the child; `model` a value set
through `set_config_option` when the child lists a `category: "model"`
option; `enabled` the switch. A bad row is listed `down: config:` and costs
the others nothing; only a table that is not rows refuses the extension.

## The tool

`delegate_agent {agent, prompt, session?, workdir?}` is registered where the
host serves the runner address and an enabled row exists — tool-less
otherwise. Its description is assembled from the rows' `description` keys;
its park is the longest enabled `timeout_ms`; its effect profile is bash's
worst case; it clamps itself. One resident child per (conversation, agent),
in its own process group, its environment replaced (the scrub plus the
row's `env`); `initialize` once, `session/new {cwd, mcpServers: []}` per
session, one `session/prompt` per call; `session` in the result continues
the same child session (its `workdir` fixed at birth). The child's
`agent_message_chunk`s are the result's text, its `tool_call`s and `plan`
the progress tail `rho watch` prints; a `session/request_permission` is
answered by the floor and the row's policy; an `elicitation/create` is
declined and quoted. Every line both ways lands in
`<artifacts>/acp/<agent>-<session>.jsonl`, redacted, linked from the result.

Cancel (`rho stop LOOP KEY`) sends `session/cancel` and returns inside the
pool's grace; the child lives on. A new delegation is refused while the old
prompt is still finishing cancellation. Once its response arrives, the old
updates are captured and discarded before another prompt can run, so they
cannot become part of the next answer. The wall (`timeout_ms`, or the announced
park's deadline) sends the cancel line, kills the group and answers the
timeout as data; a child that dies mid-turn is answered by name, its rows
gone and never revived. The conversation's end (`:host_ended`) releases its
children; the daemon's shutdown closes every child. If release races a child
that is still starting, that start reaps its own process and publishes no
session; a replacement child for the same conversation stays independent.

## The verbs and the route

```
rho acp-agents                     # the rows (launch redacted, env names masked) and the daemon's live children
rho acp-agents probe NAME          # spawn from here, print agentInfo, capabilities and each auth method's type, exit
rho acp-agents enable|disable NAME # save the switch; restart rho to apply it
rho acp-agents sessions            # the daemon's table
rho acp-agents kill SESSION        # POST /acp/kill — the session's whole child, KILLed
rho acp-agents logs SESSION        # the session's capture
```

`GET /acp` answers `{agents: [...], sessions: [...]}`.

CLI switches and WebUI settings use the same configuration operation. This
integration keeps process-wide child sessions and requires a daemon restart for
changed rows or extension removal. A live change is refused before modifying its
active children. Stop rho, update the rows or switches, then start it again;
without a running daemon the configuration is saved for that next start.
Ordinary unrelated settings changes preserve the existing sessions.

## The suite

```sh
cd agents/rho/rho-acp-client && bundle exec rake        # test, rubocop, rbs
```

`test/test_helper.rb` requires rho's test support tree by relative path
(`RhoTest.host`, the host a loader hands an extension without booting a
daemon) and spawns the harness's scripted agent
(`e2e/support/acp_fixture/agent.rb`) under the scrubbed child environment,
so the table, the call, the call_tool, cancel, the wall, a death and the release
are proven on the daemon's own handle. The e2e lane is
`e2e/test/rho_acp_client_test.rb`. CI runs the suite as
`agent_rho_acp_client`.
