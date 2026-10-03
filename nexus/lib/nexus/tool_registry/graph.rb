module Nexus
  module ToolRegistry
    # The graph family's entries — `nexus.graph.*` and `nexus.human.ask`,
    # the graph's own question to a person: `compose`, `task`, `ask`. ONE
    # SLICE of the live table: the bytes of each entry are the kernel's
    # model-facing text and are pinned by `contracts:generate`
    # (tools.json); `LIVE` is the four slices in order. `Tool` and the
    # effect constants are the registry's own.
    module Graph
      TOOLS = [
        Tool.new(
          canonical: "nexus.graph.compose",
          name: "compose",
          template: <<~TEXT.strip,
            Plain tool calls in ONE message already run at the same time: for a
            few independent reads, greps or commands you need neither {{compose}} nor
            {{task}}. When you will read the answers yourself — one job, or several
            whose answers you merge — use `{{task}}` calls, several in ONE message;
            you keep the conclusion, not the file dumps. A long command whose result
            you want later is one `{{task}}` call, never a one-step `{{compose}}`. Use
            `{{compose}}` when the answers must go on to further steps without passing
            through you: verifiers or judges whose answers one later step counts or
            weighs, a chain per item where each item moves on as soon as its own
            step is done, or a question for a person in the middle of the work. When
            a fan's items are not in the request, list them first with plain calls,
            then fan with `{{task}}` calls or pass them to `{{compose}}` in `params`. Read
            what one `{{compose}}` delivers before you plan the next.

            `script` is the BODY of a JavaScript function. `g` and `params` are
            already in scope: write statements, do not wrap them in a function.
            This first script only DESCRIBES work — no clock, no randomness, no I/O,
            nothing to await. A builder returns a handle for its step, not a result:
            never put that handle in a prompt or tool input. Pass handles in
            `after` or `results` instead. The kernel runs the graph and delivers the
            results to you later, as a message that is not from the person.

              g.tool({ name, input, after? })      // run one of your tools; after adds waits only
              g.model({ prompt, tools?, after?, results? }) // a fresh agent with an EMPTY context: it sees its
                                                   //   prompt and the results you hand it, not this conversation;
                                                   //   it has your tools except {{task}} and {{compose}}
              g.ask({ prompt, after? })             // ask a person; their answer is this step's output
              g.wait({ task, agent_loop?, timeout_ms?, after? }) // observe an existing task by its launch receipt
              g.script({ script, params?, after?, results? }) // a later pure JavaScript stage over the results you hand it
              g.parallel([ ...steps ], { until? }) // run these at once; until: how many successes end the
                                                   //   fan — "all" (default), "any", or a number

            STEPS RUN IN THE ORDER YOU WRITE THEM, one after another. Only steps
            inside one g.parallel([...]) run at the same time.
            A STEP READS ONLY WHAT YOU HAND IT. `results: [a, b]` on a model or
            script hands that step the results of a and b, in that order — a model
            ahead of its prompt, a script as results[0], results[1] — and waits for
            them. `results:` takes any list of handles: `results: runs` for an
            array you built with .map. A model step without `results:` reads its
            prompt alone, whatever ran before it: nothing reaches a step by
            position, and no step sees another step's conversation. Every result
            no step reads comes back to you.
            `after: [earlierHandle, ...]` on any leaf adds a wait without a result.
            Neither `results:` nor `after:` removes the waits of written order.
            Every tool result, read by a model step or delivered to you, names the
            call that produced it: the tool and the start of its input.
            Only preceding leaf handles and races from this script are valid,
            never an "all" group, a string key, a future step, or a task from an
            earlier call. A race stops the members it did not select, so a later
            step names the race, never one of its members:
            `const race = g.parallel([a, b, c], { until: "any" })`, then
            `results: [race]` reads what the race selected. A model step reading it
            sees each selected tool result named by its call, so a race's members
            need no extra step to name them.
            To observe work from an earlier call, g.wait names the actual task
            and optional source agent_loop from its launch receipt. Its target
            is not a handle and is never prefixed by this call; use after and
            results for steps in this script. A later step reads what a g.wait
            observed only through results: [w].
            To keep a chain from waiting for unrelated work, put the whole chain
            beside that work: g.parallel([[read, review], other]). A step after
            an "all" group still waits for every member.

              const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
              const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app lib" } });
              g.parallel([tests, lint]);
              const summary = g.model({ prompt: "Summarise the test and lint results for app/ and lib/. Name each failure as file:line.", results: [tests, lint] });
              const answer = g.ask({ prompt: "Is this summary right? Answer yes, or say what to change." });
              g.model({ prompt: "Write the final report, applying the reviewer's answer.", results: [summary, answer] });

              g.parallel(["test/models", "test/controllers"].map((dir) => {
                const run = g.tool({ name: "bash", input: { command: "bin/rails test " + dir } });
                return [run, g.model({ prompt: "Name each failing test under " + dir + " as file:line.", results: [run] })];
              }));  // two pairs at once; each model step is handed only its own run

            For shared inputs with independently ready readers, make the
            producers and readers peers of the SAME group:

              const a = g.tool({name: "bash", input: {command: "git diff"}});
              const b = g.tool({name: "bash", input: {command: "bin/rails test"}});
              const c = g.model({prompt: "Review the patch.", results: [a]});
              const d = g.model({prompt: "Assess the patch and test results.", results: [a, b]});
              g.parallel([a, b, c, d]); // C needs only A; D needs A and B, never C
              g.model({prompt: "Combine the reviews.", results: [c, d]});

            Beside the examples above, two shapes cover most work. A CHAIN PER ITEM
            is the per-directory pairs: each item moves on as soon as its own step
            is done. A PANEL is a fan of verifiers or judges, each briefed alone,
            and one reader that names them all — a g.model, since weighing them
            takes judgement (an "all" g.parallel of single steps returns their
            handles):

              const lenses = ["data loss", "locking", "rollback"];
              const reviews = g.parallel(lenses.map((lens) => g.model({ prompt: "Read db/migrate/20260927_split_accounts.rb. Through the " + lens + " lens only: is it safe to run on production? Answer `ship` or `hold` and the one risk that decides it." })));
              g.model({ prompt: "Weigh the three reviews; answer `ship` or `hold` and the deciding risk.", results: reviews });

            To compute from future output without a model round, place g.script.
            Its `script` is another function BODY with `g`, `params`, and `results`
            in scope. Its `params` is the stage's own `params` option: nothing from
            the outer script, neither its variables nor its `params`, reaches it.
            `results[i]` is the complete result envelope for the i-th
            declared handle, in that order: `status`, `is_error`, `output` (text),
            `content`, `structured_content` (the tool's JSON), and `error`.
            For a race, `results[i]` is the first envelope it selected, or the
            race's failure when it failed; `results[i].selected` lists what it
            hands you, first finisher first, a failure last.
            Check failure before parsing. Use `.output` for text, or the tool's
            documented `.structured_content`; the handle itself has neither.
            The stage sees ONLY explicitly declared results, not prior history.

            A stage either returns a JSON value (null is valid, never return a
            handle), OR builds steps with g and returns nothing. For a dynamic
            list: compute concrete inputs, map them to g.tool, g.parallel the
            handles, then end with ONE step such as g.model or another g.script
            whose `results` name them. An empty list must return a value or place
            a fallback leaf: g.parallel([]) is invalid. An expansion cannot end at
            a bare fan or race. Its final leaf's output is the stage result;
            internal results do not escape that boundary. For example:

              g.script({script: `
                const read = g.tool({name: "bash", input: {command: "git diff"}});
                g.script({results: [read], script: "const r = results[0]; if (r.status !== 'completed' || r.is_error) throw new Error('git diff failed'); return {patch: r.output};"});
              `});

            The compose call's top-level `script` is NOT a result boundary: what no
            step reads comes back to you, so end the work with one step that reads
            the rest. When the list itself is computed from results, put the
            listing, fan and reducer inside ONE g.script task, as the example does;
            only its final leaf crosses that boundary.

            No async/await, Promises, I/O, or waiting inside JavaScript. Every
            stage is a fresh bounded evaluation; the kernel runs its tasks.
            Use a g.model step when selecting or interpreting results needs
            reasoning rather than a pure calculation. Never guess future input.

            A model step with no `model:` runs as the model you are — do not
            guess a model name — and has your tools except {{task}} and {{compose}},
            unless `tools` names fewer.

            By default this call runs in the background: your next round does not
            wait for it, and its results reach you as a message not from the person —
            never poll for them, and never write as though you already know them.
            `wait: true` on the call makes the next round wait for the results.

            `lifetime: "turn"` requires this reply to consume and synthesize the
            results before becoming final, even when the call does not wait.
            `lifetime: "conversation"` delivers unwaited results in a new turn after
            this reply, even if they finish sooner.
            Omit to inherit the calling work's lifetime; ordinary replies default
            to conversation lifetime. Dependencies and explicit stops still apply.
            `wake: "passive"` records a completion after the final answer as
            conversation history without starting another reply. Omit to inherit
            the calling work's wake mode; ordinary replies default to "auto".
            `wait: true` and turn-lifetime joining still consume results in this
            reply. Standalone loops have no later turn and await all results.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "script" => {
                "type" => "string",
                "description" => "The builder script.",
              },
              "params" => {
                "type" => "object",
                "description" =>
                  "Values the script reads as `params`. Everything the script " \
                  "branches on must arrive here — it cannot look anything up.",
              },
              "lifetime" => {
                "type" => "string",
                "enum" => %w[turn conversation],
                "description" =>
                  "turn: consume the work's result before this reply becomes final. " \
                  "conversation: permit it to finish afterward. Omit to inherit; " \
                  "ordinary replies default to conversation. Independent of immediate waiting.",
              },
              "wake" => {
                "type" => "string",
                "enum" => %w[auto passive],
                "description" =>
                  "auto: a later completion may start a new reply. " \
                  "passive: record it in conversation history without starting a reply. " \
                  "Omit to inherit; ordinary work defaults to auto. Waiting and lifetime are unchanged.",
              },
              "wait" => {
                "type" => "boolean",
                "default" => false,
                "description" =>
                  "true: the next round waits for the results. " \
                  "false (the default): the next round continues alongside the work. " \
                  "Lifetime independently controls whether final delivery waits.",
              },
            },
            "required" => ["script"],
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentLoops::Compose::Run", job: "AgentLoops::ComposeJob",
        ),

        Tool.new(
          canonical: "nexus.graph.wait", name: "wait",
          template: <<~TEXT.strip,
            Wait for an existing task when its result is needed before continuing.
            Name the task key returned when it started; to observe work from an
            earlier turn, also name that execution's agent_loop UUID. The target
            must belong to this conversation, or this same standalone execution.
            This waits for generated work and the original spawned reply, not the
            launch receipt. Already completed work returns immediately. A timeout
            or cancellation ends only this wait; the target and its normal result
            delivery continue. Repeating a wait reads the available result without
            restarting the target or consuming mailbox messages.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "task" => { "type" => "string", "description" => "The existing task key." },
              "agent_loop" => { "type" => "string", "description" => "Source execution UUID; omit for this execution." },
              "timeout_ms" => { "type" => "integer", "minimum" => 1,
                "description" => "Finite waiting duration in milliseconds; defaults to one hour, at most 24 hours effective." },
            },
            "required" => ["task"],
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentLoops::WaitTool::Run", job: "AgentLoops::WaitToolJob",
        ),

        # The task declaration distinguishes a bounded branch from a
        # persistent child conversation and illustrates delegation in the
        # first message. Runner tool names and project-specific commands
        # belong to the agent application's guidance. The claude preset
        # adapts this template by replacing the wait paragraph.
        Tool.new(
          canonical: "nexus.graph.task",
          name: "task",
          template: <<~TEXT.strip,
            Give one bounded job to a new agent that starts with an EMPTY
            context. It sees only `prompt`, not this conversation, so say which
            files, what question, and the shape of the answer you want back. It
            has your tools except `{{task}}` and `{{compose}}`, unless `tools` names
            fewer.

            The task runs in the background: this call answers at once with the
            task's id, and its answer is delivered to you later as a `<task_result>`
            block whose `task` attribute is that id, in a message that is not from
            the person. A task is a step of your own work, not a conversation: it
            takes no further messages, and a `<task_result>` that also carries a
            `conversation` attribute is from a conversation you spawned, not from a
            task. Until the answer arrives do not poll, run the same command
            yourself, guess its answer, or edit the files it is working on. If
            `{{wait}}` is available, use it later when that result is needed before
            continuing. To run
            several jobs at once, put several `{{task}}` calls in ONE message; they run
            at the same time:

                {{task}}({prompt: "Review app/models/user.rb for N+1 queries. Answer file:line and a fix, or 'none'."})
                {{task}}({prompt: "Run the test suite. Answer the failing tests as file:line, or 'all green'."})

            `wait: true` means your next round WAITS for the task: the `<task_result>` is
            this call's result, and several waited calls in one message answer
            together, in the order you asked. Use the default for a long test run or
            build while you do other work; use `wait: true` when you need the answer
            before you can continue.

            `lifetime: "turn"` requires this reply to consume and synthesize the
            task's answer before becoming final, independently of immediate waiting.
            `lifetime: "conversation"` delivers an unwaited result in a new turn
            after this reply, even if the task finishes sooner.
            Omit to inherit the calling work's lifetime; ordinary replies default
            to conversation lifetime. Dependencies and explicit stops still apply.
            `wake: "passive"` records a completion after the final answer as
            conversation history without starting another reply. Omit to inherit
            the calling work's wake mode; ordinary replies default to "auto".
            `wait: true` and turn-lifetime joining still consume results in this
            reply. Standalone loops have no later turn and await all results.

            Delegate from what the person told you, in your FIRST message — do not
            look around the project first to write a better prompt: the task has
            your tools and looks for itself — and do your own part beside it, in
            the same message:

                "Find every place that reads the retry limit; meanwhile, what does the README say this service does?"
                → one message: {{task}}({prompt: "Find every place in this repository that reads the retry limit. Answer file:line for each, or 'none'."}) beside your own read of the README.

            Use `{{task}}` when the work needs a model and would fill your context (a
            review, a search across the whole tree, a test run whose failures you
            want summarised — you keep the conclusion, not the file dumps), for a
            long command whose result you want later, or for several jobs at once
            whose answers you will read yourself; not for a file or a few greps you
            can do yourself, several in one message.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "prompt" => {
                "type" => "string",
                "description" =>
                  "What to do and what to answer with. The task sees only this " \
                  "text, so name the files, the question, and the shape of the answer.",
              },
              "lifetime" => {
                "type" => "string",
                "enum" => %w[turn conversation],
                "description" =>
                  "turn: consume the work's result before this reply becomes final. " \
                  "conversation: permit it to finish afterward. Omit to inherit; " \
                  "ordinary replies default to conversation. Independent of immediate waiting.",
              },
              "wake" => {
                "type" => "string",
                "enum" => %w[auto passive],
                "description" =>
                  "auto: a later completion may start a new reply. " \
                  "passive: record it in conversation history without starting a reply. " \
                  "Omit to inherit; ordinary work defaults to auto. Waiting and lifetime are unchanged.",
              },
              "wait" => {
                "type" => "boolean",
                "default" => false,
                "description" =>
                  "true: the next round waits and the answer is this call's result. " \
                  "false (the default): the next round continues alongside the task. " \
                  "Lifetime independently controls whether final delivery waits.",
              },
              "tools" => {
                "type" => "array",
                "items" => { "type" => "string" },
                "description" =>
                  "Names from your own tool list, to give the task fewer tools. " \
                  "Omit to give it all of yours except {{task}} and {{compose}}.",
              },
            },
            "required" => ["prompt"],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentLoops::TaskTool::Run", job: "AgentLoops::TaskToolJob",
        ),
        Tool.new(
          canonical: "nexus.human.ask",
          name: "ask",
          template: <<~TEXT.strip,
            Ask the person one question and wait for the answer. Use it when
            you cannot proceed without a decision only they can make — which of
            two designs, whether to delete something, a credential you do not
            have. Do not use it to report progress or to confirm something you
            can check yourself.

            This turn waits. The answer arrives as `<answer task="r3t1">`, a
            message that is not the person typing to you anew — read it as the
            answer to your question and continue the work.

            Example: `{{ask}}({prompt: "Migrating users.email to citext drops the
            existing index for ~2 min in production. Proceed, or schedule it
            for a maintenance window?"})`
          TEXT
          # THE CHOICES AS DATA: `options` and `multi` ride beside the question,
          # as claude-code's `AskUserQuestion`, codex's `request_user_input` and
          # opencode's `question` carry them — stored on the await row, shown to
          # the person on every read of it. The three sentences are the
          # cleanup's minimal words; the paid window BENCHES them (a
          # model-facing shape is never hand-tuned).
          parameters: {
            "type" => "object",
            "properties" => {
              "prompt" => {
                "type" => "string",
                "description" => "The one question.",
              },
              "options" => {
                "type" => "array",
                "items" => { "type" => "string" },
                "description" => "The choices, if there are choices: one string each, in the order to show them.",
              },
              "multi" => {
                "type" => "boolean",
                "description" => "true when more than one choice may be taken. Default false.",
              },
            },
            "required" => ["prompt"],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentLoops::Asks::Run", job: "AgentLoops::AskJob",
        ),
      ].freeze
    end
  end
end
