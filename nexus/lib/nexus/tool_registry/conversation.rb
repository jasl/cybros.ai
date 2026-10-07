module Nexus
  module ToolRegistry
    # The conversation family's entries (`nexus.conversation.*`): `spawn`,
    # `send`, `status`, `cancel`. ONE SLICE of the live table: the bytes
    # of each entry are the kernel's model-facing text and are pinned by
    # `contracts:generate` (tools.json); `LIVE` is the four slices in
    # order. `Tool` and the effect constants are the registry's own.
    module Conversation
      TOOLS = [
        # Persistent delegation opens a child conversation under the
        # caller's profile or a named peer and can outlive one answer. The
        # codex preset adapts this same template by replacing its wait
        # clause, so the canonical tool and alias share the remaining
        # guidance.
        Tool.new(
          canonical: "nexus.conversation.spawn",
          name: "spawn",
          template: <<~TEXT.strip,
            Open a conversation with another agent and give it a job. Without
            `agent` it is answered by a fresh copy of yourself with an empty
            context (a subagent); with `agent`, by that agent's own engine, tools
            and memory (a peer). Unlike `{{delegate_task}}`, a spawned conversation
            persists: you can `{{send}}` it more messages, read its `{{status}}`,
            and `{{cancel}}` it. Its reply reaches you as a `<task_result task="…"
            conversation="…">` message that is not from the person; `wait: true`
            waits for the first reply. Use `{{delegate_task}}` for one bounded job that
            ends with one answer; use `{{spawn}}` when the work needs another
            agent's tools or memory, or a back-and-forth.

            `lifetime: "turn"` requires this reply to consume and synthesize the
            child's report before becoming final. That obligation survives an
            expired or canceled immediate wait. The child's initial execution
            inherits turn lifetime; explicitly cross-turn work may remain afterward.
            `lifetime: "conversation"` delivers an unwaited report in a new turn
            after this reply, even if the child finishes sooner.
            Omit to inherit the calling work's lifetime; ordinary replies default
            to conversation lifetime. Later messages are independent requests.
            `wake: "passive"` records an unwaited reply in your conversation
            history without starting another turn. Omit to inherit the calling
            work's wake mode; ordinary replies default to "auto". A waited reply
            and the turn-lifetime reporting obligation are unchanged.

            Spawn from what the person told you, in your FIRST message — do not
            look around the project first to write a better brief: the agent has
            tools of its own and looks for itself — and do your own part beside
            it, in the same message:

                "Get an agent I can keep talking to onto the flaky login tests; meanwhile, what does the README say this service does?"
                → one message: {{spawn}}({label: "login-tests", prompt: "The login tests are flaky. Find why, fix it, and answer with what you changed."}) beside your own read of the README.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "prompt" => {
                "type" => "string",
                "description" =>
                  "The job, as the first message of the new conversation. It sees " \
                  "only this text, so name the files, the question, and what to answer with.",
              },
              "agent" => {
                "type" => "string",
                "description" =>
                  "The agent that answers the conversation, as its @handle or its " \
                  "public id. Omit for a fresh copy of yourself.",
              },
              "label" => {
                "type" => "string",
                "description" =>
                  "A short name for the conversation, unique among the ones you " \
                  "spawned here (lowercase letters, digits, `_`, `-`). Optional.",
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
                  "true: the next round waits for the first reply as this call's result. " \
                  "false (the default): the next round continues alongside the child. " \
                  "Lifetime independently controls whether final delivery waits.",
              },
              "default_runner_executor_public_id" => {
                "type" => ["string", "null"],
                "description" => "Runner UUID for the new conversation; null clears the default. Omit to inherit the caller default when eligible.",
              },
              "model" => {
                "type" => "string",
                "description" =>
                  "The model the conversation runs on, as provider/model, when its " \
                  "agent has none of its own. Omit for the model you are running on.",
              },
            },
            "required" => ["prompt"],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::Spawn::Run", job: "AgentRuns::ConversationToolJob",
        ),

        # THE THREE VERBS ON A SPAWNED CONVERSATION: one executor keyed by
        # the wire word. NEW bytes, measured by the SP rows of the task
        # bench: written as designed and never tuned here. `to` is the label
        # `spawn` gave the child or a public id: WHERE, on all three.
        # `agent` on `send` alone is WHO: the principal inside that
        # conversation the message is for.
        Tool.new(
          canonical: "nexus.conversation.send",
          name: "send",
          template: <<~TEXT.strip,
            Post a message into a conversation you spawned, or one you may
            write in, except your parent or any ancestor conversation. To
            report to your parent, finish your reply; it is returned automatically.
            By default, it queues for a new reply after the current reply ends,
            or starts one immediately if idle; a scheduled message also waits
            until its delivery time. `steer: true` joins the running reply at
            its next model boundary; it does not interrupt an in-flight model
            request or tool. On an idle conversation it queues a new reply. `agent`
            addresses one agent in that conversation; without it the
            conversation's own agent replies. A reply, if any, reaches you
            in a new turn after your current reply, even if it finishes sooner;
            this message is not from the person. `wake: "passive"`
            stores an owed reply in your conversation history without starting
            another turn. It does not change delivery to the recipient; a steer
            joining an existing reply keeps that reply's original wake policy.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "to" => {
                "type" => "string",
                "description" =>
                  "The conversation: the label you gave it when you spawned it, or its public id.",
              },
              "agent" => {
                "type" => "string",
                "description" =>
                  "The agent in that conversation this message is for, as its @handle " \
                  "or its public id. Omit for the conversation's own agent.",
              },
              "message" => {
                "type" => "string",
                "description" => "The message, as the person would write it.",
              },
              "steer" => {
                "type" => "boolean",
                "default" => false,
                "description" =>
                  "true: join the running reply at its next model boundary, without interrupting " \
                  "an in-flight model request or tool. false (the " \
                  "default): deliver after that reply ends, or at once if nothing is running.",
              },
              # THE CLOCK ON THE MESSAGE: both spellings, because NO CLOCK
              # REACHES THE MODEL — `deliver_in` is the form a clockless
              # model can use, `deliver_at` for one that was told a
              # wall-clock time; the text says which is which and never
              # "prefer" (the paid window benches which one models reach
              # for). Written as designed, never tuned here.
              "deliver_in" => {
                "type" => "string",
                "description" =>
                  "Deliver after this delay from now: 90s, 20m, 2h or 1d. Omit to deliver now. " \
                  "Not with steer. Send to your own conversation to wake yourself later.",
              },
              "deliver_at" => {
                "type" => "string",
                "description" =>
                  "Deliver at this time, as an ISO 8601 time with a UTC offset (2026-09-16T09:00:00Z). " \
                  "Use it only when you were told the time; otherwise deliver_in. Not with steer.",
              },
              "wake" => {
                "type" => "string",
                "enum" => %w[auto passive],
                "description" =>
                  "auto: a later completion may start a new reply. " \
                  "passive: record it in conversation history without starting a reply. " \
                  "Omit to inherit; ordinary work defaults to auto. Waiting and lifetime are unchanged.",
              },
              "model" => {
                "type" => "string",
                "description" =>
                  "The model the reply runs on, as provider/model, when the agent " \
                  "answering has none of its own. Omit for the model you are running on.",
              },
            },
            "required" => %w[to message],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::ConversationTool::Run", job: "AgentRuns::ConversationToolJob",
        ),
        Tool.new(
          canonical: "nexus.conversation.status",
          name: "status",
          template: <<~TEXT.strip,
            Read a conversation you spawned, or one you may read: whether a
            reply is running there or it is idle, how many messages wait in
            its queue, and who answers it. Do not poll: replies reach you as
            messages.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "to" => {
                "type" => "string",
                "description" =>
                  "The conversation: the label you gave it when you spawned it, or its public id.",
              },
            },
            "required" => ["to"],
            "additionalProperties" => false,
          },
          effect_profile: READ_ONLY_CLOSED,
          executor: "AgentRuns::ConversationTool::Run", job: "AgentRuns::ConversationToolJob",
        ),
        Tool.new(
          canonical: "nexus.conversation.cancel",
          name: "cancel",
          template: <<~TEXT.strip,
            Stop work owned by a conversation you spawned, or one you may
            write in, including background work, pending results, and work
            derived from those executions. Independent later requests in its
            spawned conversations continue. Your own active request may still
            receive the canceled outcome of a reply it was waiting for.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "to" => {
                "type" => "string",
                "description" =>
                  "The conversation: the label you gave it when you spawned it, or its public id.",
              },
            },
            "required" => ["to"],
            "additionalProperties" => false,
          },
          effect_profile: GRAPH_WRITE,
          executor: "AgentRuns::ConversationTool::Run", job: "AgentRuns::ConversationToolJob",
        ),
      ].freeze
    end
  end
end
