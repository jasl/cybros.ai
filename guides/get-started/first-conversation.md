# Your first conversation

Connect rho to Nexus, save a default model, start the daemon and send your first
terminal request. This walkthrough uses a local source checkout with Nexus
already running at `http://localhost:3000` and a model provider configured.

## Open the rho directory

From the repository root:

```sh
cd agents/rho/rho
bundle install
```

Run the commands below from this directory. If you used the
[host installer](connect-a-host-installation.md), use `rho` in place of
`bundle exec exe/rho`.

## Save the default model

```sh
bundle exec exe/rho setup --nexus-url http://localhost:3000
```

For a new Nexus, create the owner account at `http://localhost:3000/setup` first.
Enter a setup secret if your installation requires one. Follow the wizard's
sign-in and device approval steps if rho is not connected yet.

This example keeps an existing login, skips Telegram and provider configuration,
and selects an available model:

```text
Keeping the existing rho and Nexus login.
Set up Telegram messaging? (y/n) [y]: n
Configure a model provider as a Nexus administrator? (y/n) [y]: n
Default model
  1. deepseek/deepseek-flash
  2. deepseek/deepseek-v4-pro
Choose a number [1]: 1
Default model saved: deepseek/deepseek-flash
Availability was checked without making a paid model request.
Configuration saved. A running rho applies changes immediately; otherwise start it with `rho server`.
Check `rho status`, then try `rho run "Say hello"` (a normal, potentially billed model request).
```

Your model list depends on Nexus configuration. If no usable model is listed,
configure one through [Models and providers](../operate/models-and-providers.md),
then rerun setup.

## Choose conversation and title models

To change model settings after setup, list the models available to rho:

```sh
bundle exec exe/rho models
```

For example:

```text
deepseek/deepseek-flash  text_generation
deepseek/deepseek-v4-pro  text_generation
kimi_code/kimi-for-coding  text_generation
```

Use references from your own list. This example selects Kimi as the default
conversation model and DeepSeek Flash for generated conversation titles:

```sh
bundle exec exe/rho settings '{"default_model":"kimi_code/kimi-for-coding","conversation_title_model":"deepseek/deepseek-flash"}'
bundle exec exe/rho settings
```

The second command shows the saved settings. Check that `default_model` is
`kimi_code/kimi-for-coding` and `conversation_title_model` is
`deepseek/deepseek-flash`. Other settings are preserved. A running rho applies
the changes immediately. See [Command line](../reference/cli.md) for the settings
command syntax.

## Check the daemon

```sh
bundle exec exe/rho status
```

After setup, the status can include:

```text
nexus:     http://localhost:3000
mode:      full
instance:  b3597805
daemon:    not running
state:     connected (no daemon running)
```

The connection is saved, but setup does not start the daemon. A request at this
point fails:

```sh
bundle exec exe/rho run "Say hello"
```

```text
rho run: no local daemon is running; start one with `rho server`
```

## Start rho

In one terminal, start the foreground daemon and leave it running:

```sh
bundle exec exe/rho server
```

The startup output includes its local address and working directory. In this
example:

```text
rho 0.1.0 listening on http://127.0.0.1:56588 (active, mode full)
console: open it with `rho console`
announcement: /Users/guochunzhong/.rho/tmp/announcement.json
log:  /Users/guochunzhong/.rho/log/rho.log
work: /Users/guochunzhong/.rho/work
```

In a second terminal, enter the same `agents/rho/rho` directory and check status
again, using the same rho home:

```sh
bundle exec exe/rho status
```

Look for `daemon: running`, `state: signed in`, a runner serving tools and your
selected model. Relevant lines from this example are:

```text
daemon:    running at http://127.0.0.1:56588 (pid 10401)
state:     signed in
runner:    01a15402-bea1-7ff5-9bad-08c233df9bae serving 22 tools (socket connected, swept 7)
  member: live
  executor_transport: live
  runner_transport: live
workspace: dedicated rho on s-MBP-M4-Pro.local (01a15405-04ed-7c0e-aa4d-4d453e082dd6)
model:     kimi_code/kimi-for-coding
```

The port, IDs, hostname, paths and tool count vary by installation.

## Send a request

In the second terminal:

```sh
bundle exec exe/rho run "hello"
```

This makes a normal model request and can incur provider charges. A successful
run prints the conversation, turn and run IDs, streams the reply and finishes
with `status: completed`:

```text
conversation: 01a15405-99b8-7e24-a97b-2e2eb71d0de2
turn:         01a15405-9cb5-7ad5-8a37-6bb55363ec50
run:         01a15405-9d00-728b-9205-26da2101ef07
adaptations:  default (gem)
  running        r1
  │ hello
  │
  │ I'm here and ready. Anything you'd like me to look at or work on?
  completed      r1
status:    completed

hello

I'm here and ready. Anything you'd like me to look at or work on?
```

Your reply will vary. Conversation history is stored in Nexus. To continue in
the browser, run `bundle exec exe/rho console --open`. Use the browser for work
that needs answers to questions or tool approvals.

## Next

- [Terminal requests](../use/terminal-requests.md) for options, exit codes and Docker commands
- [Conversations](../use/conversations.md) for interactive work
- [Approvals and questions](../use/approvals-and-questions.md)
