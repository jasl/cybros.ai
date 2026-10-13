module Nexus
  module ToolRegistry
    # The graph family's entries — `nexus.graph.*` and `nexus.human.ask`,
    # the graph's own question to a person: `delegate_task`, `wait`, `ask`. ONE
    # SLICE of the live table: the bytes of each entry are the kernel's
    # model-facing text and are pinned by `contracts:generate`
    # (tools.json); `LIVE` is the four slices in order. `Tool` and the
    # effect constants are the registry's own.
    module Graph
      TOOLS = [
        Tool.new(
          canonical: "nexus.graph.wait", name: "wait",
          template: <<~TEXT.strip,
            Wait for an existing task when its result is needed before continuing.
            Name the task key returned when it started; to observe work from an
            earlier turn, also name that execution's run_public_id. The target
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
              "run_public_id" => { "type" => "string", "description" => "Source execution UUID; omit for this execution." },
              "timeout_ms" => { "type" => "integer", "minimum" => 1,
                "description" => "Finite waiting duration in milliseconds; defaults to one hour, at most 24 hours effective." },
            },
            "required" => ["task"],
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::WaitTool::Run", job: "AgentRuns::WaitToolJob",
        ),

        # The task declaration distinguishes a bounded branch from a
        # persistent child conversation and illustrates delegation in the
        # first message. Runner tool names and project-specific commands
        # belong to the agent application's guidance. The claude preset
        # adapts this template by replacing the wait paragraph.
        Tool.new(
          canonical: "nexus.graph.delegate_task",
          name: "delegate_task",
          template: <<~TEXT.strip,
            Give one bounded job to a new agent that starts with an EMPTY
            context. It sees only `prompt`, not this conversation, so say which
            files, what question, and the shape of the answer you want back. It
            inherits your tools unless `tools` names fewer, including the ability
            to delegate again when `{{delegate_task}}` remains declared. `model`
            selects a provider/model for this task only; omission inherits your
            configured model. An unavailable explicit selection is refused.

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
            several jobs at once, put several `{{delegate_task}}` calls in ONE message; they run
            at the same time:

                {{delegate_task}}({prompt: "Review app/models/user.rb for N+1 queries. Answer file:line and a fix, or 'none'."})
                {{delegate_task}}({prompt: "Run the test suite. Answer the failing tests as file:line, or 'all green'."})

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
            reply. Standalone runs have no later turn and await all results.

            Delegate from what the person told you, in your FIRST message — do not
            look around the project first to write a better prompt: the task has
            your tools and looks for itself — and do your own part beside it, in
            the same message:

                "Find every place that reads the retry limit; meanwhile, what does the README say this service does?"
                → one message: {{delegate_task}}({prompt: "Find every place in this repository that reads the retry limit. Answer file:line for each, or 'none'."}) beside your own read of the README.

            Use `{{delegate_task}}` when the work needs a model and would fill your context (a
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
              "model" => {
                "type" => "string",
                "description" =>
                  "Optional provider/model reference for this task at that model's reasoning default. " \
                  "Omit to inherit your configured model. Does not change your model or any agent profile.",
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
                  "Omit to give it all of yours, including {{delegate_task}} when declared.",
              },
            },
            "required" => ["prompt"],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::DelegateTaskTool::Run", job: "AgentRuns::DelegateTaskToolJob",
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
          executor: "AgentRuns::Asks::Run", job: "AgentRuns::AskJob",
        ),
      ].freeze
    end
  end
end
