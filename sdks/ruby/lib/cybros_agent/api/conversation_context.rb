require "securerandom"

module CybrosAgent
  module Api
    # ONE conversation, from the Agent's side: its own lifecycle verbs, its
    # two nested surfaces (the input queue, the timeline), and the three
    # feeds a follower can take.
    #
    # NOTHING IS AUTHORED HERE DIRECTLY. A caller enqueues an INPUT and the
    # kernel materializes it into a turn at the next boundary — see
    # `inputs`. That indirection is what makes a mid-run arrival wait as a
    # durable row instead of racing the reply, and hiding it behind a
    # `send_message` would hide the queue the caller has to reason about.
    class ConversationContext
      include ConversationProjections
      include Fields

      attr_reader :workspace_public_id, :public_id

      EVENTS_CHANNEL = "AgentAPI::V1::ConversationEventsChannel".freeze

      def initialize(dispatch:, workspace_public_id:, public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
        @public_id = required_string_snapshot(public_id, "public_id")
      end

      def fetch = shape(Conversation, @dispatch.call(path), "conversation")

      def update(title: UNSET, metadata: UNSET)
        body = fields(title:, metadata:)
        raise ArgumentError, "provide title or metadata" if body.empty?

        shape(Conversation, @dispatch.call(path, method: :patch, body: { "conversation" => body }), "conversation")
      end

      # ARCHIVE IS THE RECYCLE BIN, delete is the tombstone. Archiving is
      # reversible and keeps the conversation readable; deleting refuses
      # while work is running and is expected to follow a cancel.
      def archive = shape(Conversation, @dispatch.call("#{path}/archive", method: :post), "conversation")
      def unarchive = shape(Conversation, @dispatch.call("#{path}/unarchive", method: :post), "conversation")

      def delete
        @dispatch.call(path, method: :delete, success: 204)
        nil
      end

      # The subagent followers, reachable only through their parent.
      def children(after: nil, limit: nil)
        page(ConversationSummary, @dispatch.call("#{path}/children", params: query(after:, limit:)), "conversations")
      end

      def inputs = InputsContext.new(dispatch: @dispatch, path: "#{path}/inputs")

      def schedules = SchedulesContext.new(dispatch: @dispatch, path: "#{path}/schedules")

      # DURABLE MEMORY — this conversation's named bindings, or its default
      # scopes (its own, its workspace's, the caller's `user/`).
      # See MemoryContext for why a conversation writes memory over HTTP
      # where an agent run calls a tool.
      def memory = MemoryContext.new(dispatch: @dispatch, path: "#{path}/memory")

      # Replace the memory roots used by future execution. Explicit nil
      # restores the default; an empty bindings list disables memory.
      def set_memory_context(memory_context:)
        answer = @dispatch.call("#{path}/memory_context", method: :post, body: { "memory_context" => memory_context })
        shape(Conversation, answer, "conversation")
      end

      # THE CONVERSATION'S OWN STORE: its client state, which
      # forks with it and which no prompt ever reads.
      def store_entries = StoreEntriesContext.new(dispatch: @dispatch, path: "#{path}/store_entries")

      def turns
        ConversationTurnsContext.new(
          dispatch: @dispatch, workspace_public_id: @workspace_public_id,
          conversation_public_id: @public_id
        )
      end

      def history
        ConversationHistoryContext.new(dispatch: @dispatch, path: "#{path}/history")
      end

      # Total and idempotent in intent, but NOT silent: a conversation with
      # nothing running answers Conflict, because "cancel" on an idle lane
      # is a caller confusion worth surfacing rather than a no-op to hide.
      def cancel
        @dispatch.call("#{path}/cancellation", method: :post, success: 202)
        nil
      end

      # Select the default for future Runner work. Existing tasks retain their
      # accepted target. Explicit nil clears the convenience default.
      def set_default_runner(executor_public_id:)
        binding = { "executor_public_id" => executor_public_id.nil? ? nil : required_string(executor_public_id, "executor_public_id") }
        answer = @dispatch.call("#{path}/default_runner", method: :put, body: { "default_runner" => binding })
        shape(Conversation, answer, "conversation")
      end

      # THE ACCESS CARRIER'S LATER CHANGE: a WHOLE replacement of the
      # default and the named entries, PUT on the nested singular resource
      # — idempotent by value with no receipt. The
      # standing is `full` on the row with write standing on the workspace
      # (the creator, the answerer, or a full entry: full control includes
      # changing permissions); a principal the row lists at `read` is 403
      # `not_authorized`, one it conceals finds the door 404. 422
      # `principal_not_eligible` for an id that may not be named (the
      # creator, the answerer, the system user, an unknown id, one named
      # twice); 422 `validation_failed` for an unknown level. Answers the
      # conversation carrying the carrier it now has; the kernel narrates
      # `access_changed` on the feed once per change, with the actor's
      # kind. An agent learns its own id from `client.profile.fetch.member.public_id`
      # and its peers' from `workspace.principals`.
      def set_access(default:, entries: [])
        carrier = access_body(default: required_string(default, "default"), entries: entries)
        answer = @dispatch.call("#{path}/access", method: :put, body: { "access" => carrier })
        shape(Conversation, answer, "conversation")
      end

      # BRANCH THE TIMELINE at a turn — the child adopts the prefix through
      # a closure and copies no content bytes. `variant_public_id` picks
      # WHICH candidate of that turn the branch keeps; omitted, it is the
      # active one.
      #
      # `side: true` shares the settled history and seals the persisted current
      # turn as an immutable reference when the parent is running or held.
      # The child owns no parent execution and places a boundary after that
      # context. Replay and budget choices still govern the emitted request;
      # shared content alone does not guarantee provider cache reuse.
      # A turn named beside `side` is not read. A side is never forked again
      # (422 `side_of_side`), never archived, and `delete` reaps it at once.
      #
      # The answer retains per-Runner first-write evidence above the fork point.
      # Restoring any supplied checkpoints is a separate client composition.
      def fork(idempotency_key:, turn_public_id: UNSET, variant_public_id: UNSET,
               title: UNSET, side: UNSET)
        required_string(idempotency_key, "idempotency_key")
        body = fields(turn_public_id:, variant_public_id:, title:, side:)
        raise ArgumentError, "provide turn_public_id or side: true" unless
          body.key?("turn_public_id") || body["side"] == true

        result = @dispatch.call_accepting(
          "#{path}/forks", method: :post, body: { "fork" => body },
          headers: { "Idempotency-Key" => idempotency_key }, success: 201
        )
        Forked.new(
          conversation: shape(Conversation, result.body, "conversation"), replayed: result.replayed,
          runner_effects: shape(RunnerEffects, result.body, "runner_effects")
        )
      end

      # Fork history, then restore each retained Runner checkpoint independently.
      # No work is transferred between Runners and this is not a global rollback.
      def rewind(turn_public_id:, idempotency_key:, variant_public_id: UNSET, title: UNSET,
                 restore_checkpoints: true, poll: RunContext::DEFAULT_REQUEST_POLL_SECONDS,
                 patience: nil, approval_rules: UNSET, restore_guard: nil)
        required_string(idempotency_key, "idempotency_key")
        forked = fork(idempotency_key:, turn_public_id:, **fields(variant_public_id:, title:).transform_keys(&:to_sym))
        restoration = if restore_checkpoints
          self.restore_checkpoints(forked.runner_effects, poll:, patience:, approval_rules:, restore_guard:)
        else
          { status: forked.runner_effects.untouched? ? "untouched" : "kept", runners: [] }
        end
        Rewound.new(conversation: forked.conversation, replayed: forked.replayed,
          fork_point: forked.runner_effects, restoration:)
      end

      # Restore only on the Runner named by each retained effect record. A failure
      # on one Runner does not erase another Runner's result or abort its restore.
      def restore_checkpoints(effects, poll: RunContext::DEFAULT_REQUEST_POLL_SECONDS,
                              patience: nil, approval_rules: UNSET, restore_guard: nil)
        return { status: "untouched", runners: [] } if effects.untouched?

        outcomes = effects.runners.map do |effect|
          outcome = restore_runner_checkpoint(effect, poll:, patience:, approval_rules:, restore_guard:)
          { runner_executor_public_id: effect.runner_executor_public_id, **outcome }
        end
        statuses = outcomes.map { |outcome| outcome.fetch(:status) }
        status = if statuses.empty?
          "unavailable"
        elsif statuses.all? { |value| value == "restored" } && !effects.unavailable?
          "restored"
        elsif statuses.include?("restored")
          "partial"
        elsif statuses.include?("failed")
          "failed"
        else
          "unavailable"
        end
        { status:, runners: outcomes, reason: effects.reason }.compact
      end

      # WHAT THIS WOULD COST, before it costs anything: assembly is
      # kernel-side, so only the server can count what the caller cannot
      # see. Write-free, and never a provider call.
      #
      # WITH `render: true` IT IS THE PREVIEW (one door): the
      # answer's `rendered` half carries the bytes the send would seal —
      # the entries as the sealed-request door reads them, the storage
      # line against the seal's bound, one evidence row per template block.
      # The caller is the author (its persona, its `user/` memory rung);
      # `to:` names the ADDRESSEE the compile runs under — `@handle` or a
      # public id, the input door's own word, resolved by the same rule —
      # defaulting to the conversation's stored answerer. `variables:` are
      # the turn's values for the addressee's declared template names;
      # `template:` an ESTIMATE-ONLY trial order under the kernel's
      # grammar, compiled in place of the addressee's and never stored
      # (422 `prompt_template_invalid` names its JSON-pointer path).
      def estimate_input(model:, prompt: UNSET, reasoning_effort: UNSET, reasoning_enabled: UNSET,
                         configuration: UNSET, history: UNSET,
                         reasoning_replay: UNSET, inline: UNSET, render: UNSET,
                         to: UNSET, variables: UNSET, template: UNSET)
        body = fields(
          model: fields(model:, reasoning_effort:, reasoning_enabled:), prompt:, configuration:, history:,
          reasoning_replay:, inline:, render:, answering_user_public_id: to, variables:, template:
        )

        shape(ConversationInputEstimate, @dispatch.call("#{path}/context_estimate", method: :post,
            body: { "context_estimate" => body }), "context_estimate")
      end

      # COMPACT NOW. The kernel picks no threshold — it repairs only what
      # it can prove will not fit — so a caller who can see the
      # conversation getting expensive says so here. Unnamed, the model
      # is the conversation's own; naming one is how a summary gets run
      # somewhere cheaper than the conversation itself.
      #
      # Answers the summary TURN, which is `running`: the summary is a
      # run-backed turn — one kernel run whose only task is the
      # summarizer — and settles through the same converger as any other.
      def compact(model: UNSET, reasoning_effort: UNSET, reasoning_enabled: UNSET)
        shape(ConversationCompaction, @dispatch.call("#{path}/compaction", method: :post,
            body: { "compaction" => fields(model:, reasoning_effort:, reasoning_enabled:) }, success: 202))
      end

      # The durable replay window: strictly after `after`, ascending. The
      # limit is a hard reject on the server rather than a clamp, so asking
      # for more than it serves raises instead of quietly returning less.
      def events(after: nil, limit: nil)
        shape(ConversationEventPage, @dispatch.call("#{path}/events", params: query(after:, limit:)))
      end

      # FOLLOWING A CONVERSATION'S LIFECYCLE, done correctly, without
      # having to know how. The events endpoint is the authority and this
      # wires it into the pump that drains it properly — a frozen head per
      # pass, dedupe by sequence, a position that advances only after the
      # caller's block returns. With no `realtime:` it needs no socket at
      # all, which is a supported way to use this API rather than a lesser
      # one.
      #
      # `items: "lifecycle"` narrows the subscription to `turn_status` —
      # where the conversation IS — for a consumer holding many and reading
      # none. The narrowing is a different broadcasting on the server, so
      # an uninterested subscriber receives nothing rather than filtering
      # what it will discard.
      def feed(position: KernelFeed::Position.start, limit: nil,
               realtime: nil, items: nil, **options)
        KernelFeed.new(
          replay: ->(cursor) { events(after: cursor, limit: limit) },
          subscribe: realtime && realtime_opener(realtime, items: items),
          position: position,
          **options
        )
      end

      def realtime_opener(client, items: nil)
        params = { workspace_id: @workspace_public_id, conversation_id: @public_id }
        params[:items] = items unless items.nil?
        Realtime::FeedSubscription.opener(
          client: client, channel: EVENTS_CHANNEL, params: params,
          # The same projection the replay page applies, so an item is the
          # same object whichever transport carried it.
          event: ->(message) { shape(ConversationEvent, message, "event") }
        )
      end

      # WHAT A TURN IS SAYING, as it says it. This feed is a TAIL, not a
      # log: it has no replay window and nothing is backfilled, so it takes
      # a socket and NOTHING ELSE — a REST-only spelling would be a method
      # that silently returns nothing forever.
      #
      # Deltas arrive while a reply runs and the settled turn arrives when
      # it terminalizes; both route by `turn_public_id`. A run-backed
      # turn's rounds settle here too, `round` and `call` under `task_key`
      # with the run's id beside the turn's. A delta that never arrives
      # costs a frame of latency, never a fact — `turns.list` is the
      # recovery path, and completion always re-states itself here.
      def transcript(realtime:)
        Realtime::FeedSubscription.opener(
          client: realtime, channel: EVENTS_CHANNEL,
          params: {
            workspace_id: @workspace_public_id, conversation_id: @public_id,
            items: "transcript",
          },
          event: ->(message) { shape(TranscriptItem, message, "event") }
        )
      end

      # WHAT THE BOUND RUNNER IS DOING RIGHT NOW: this
      # conversation's `progress` feed — a call's `bash` tail under its
      # claim, a process's output under this conversation's binding — as
      # `ProgressFrame`s. A socket and NOTHING ELSE, like `transcript`:
      # nothing durable, nothing replayed; the envelope is `{frame}`, so
      # the events mapper never sees one and this opener maps its own.
      def progress(realtime:)
        Realtime::FeedSubscription.opener(
          client: realtime, channel: EVENTS_CHANNEL,
          params: {
            workspace_id: @workspace_public_id, conversation_id: @public_id,
            items: "progress",
          },
          event: ->(message) { shape(ProgressFrame, message, "frame") }
        )
      end

      private

        def path
          "#{Workspaces::PATH}/#{path_segment(@workspace_public_id, "workspace_public_id")}" \
            "/conversations/#{path_segment(@public_id, "public_id")}"
        end

        def restore_runner_checkpoint(effect, poll:, patience:, approval_rules:, restore_guard:)
          runner = effect.runner_executor_public_id
          captured = effect.checkpoint
          if !captured&.restorable? && effect.skipped.nil?
            captured = store_checkpoint(runner, effect.run_public_id, poll:, patience:)
          end
          unless captured&.restorable?
            return { status: "unavailable", reason: "no_checkpoint", skipped: effect.skipped }.compact
          end

          reason = restore_guard&.call(runner, captured)
          return { status: "failed", reason: } if reason

          restore_request(runner, captured, poll:, patience:, approval_rules:)
        rescue Error => error
          { status: "failed", reason: error.code }
        rescue CybrosAgent::TransportError
          { status: "unavailable", reason: "transport_error" }
        end

        # A cache miss reads the original Runner's checkpoint store through
        # an explicit tool call. A Runner with no retained checkpoint reports
        # an unavailable restore without affecting other Runners.
        def store_checkpoint(runner, run_public_id, poll:, patience:)
          return nil if runner.nil? || run_public_id.nil?

          detail = request_run(runner, "checkpoints", { "run_public_id" => run_public_id }, poll:, patience:)
          return nil unless completed?(detail)

          records = Hash.try_convert(detail.structured_content)&.fetch("records", nil)
          Array(records).each do |entry|
            row = Hash.try_convert(entry)
            next unless row && row["present"] == true
            next unless String.try_convert(row["hash"])

            return checkpoint(row)
          end
          nil
        rescue Error
          nil
        end

        def restore_request(runner, captured, poll:, patience:, approval_rules:)
          input = { "checkpoint" => captured.hash, "store" => captured.store }.compact
          detail = request_run(runner, "checkpoint_restore", input,
            poll:, patience:, approval_rules:)
          task = detail.task
          if completed?(detail)
            { status: "restored", checkpoint: captured.hash, undo: undo_of(detail), **marks_of(captured) }.compact
          elsif task.status == "completed"
            { status: "failed", reason: reason_word(detail.output), undo: undo_of(detail) }.compact
          else
            { status: "failed", reason: task.error&.fetch("key", nil) }.compact
          end
        end

        def request_run(runner, tool, input, poll:, patience:, approval_rules: UNSET)
          RunsContext.new(dispatch: @dispatch, workspace_public_id: @workspace_public_id)
            .start_tool_call(runner_executor_public_id: runner, tool: tool, input: input,
              idempotency_key: SecureRandom.uuid, approval_rules: approval_rules)
            .wait_for_tool_result(poll: poll, patience: patience)
        end

        def completed?(detail)
          detail.task.status == "completed" && !detail.task.result&.fetch("is_error", false)
        end

        # The restore's own record, parsed as the fork point's is.
        def undo_of(detail)
          checkpoint(detail.metadata&.fetch("checkpoint", nil))&.hash
        end

        # WHAT THE RESTORE COULD NOT REACH: the fork point's
        # `outside` and `ignored` paths, present-only, ride the outcome so a
        # reader prints what it did not restore.
        def marks_of(checkpoint)
          { outside: checkpoint.outside, ignored: checkpoint.ignored }.reject { |_, paths| paths.empty? }
        end

        # The tool's first word — the reason a reader acts on
        # (`checkpoint_unknown`, `restore_refused`, …).
        def reason_word(output) = output.to_s[/\A[a-z_]+/]

      Forked = Data.define(:conversation, :replayed, :runner_effects) do
        def replayed? = replayed

        def public_id = conversation.public_id
      end

      # The input evidence and each Runner's restoration outcome remain distinct.
      Rewound = Data.define(:conversation, :replayed, :fork_point, :restoration) do
        def replayed? = replayed
        def public_id = conversation.public_id
        def status = restoration[:status]
        def restored? = status == "restored"
        def partial? = status == "partial"
        def untouched? = status == "untouched"
        def kept? = status == "kept"
        def unavailable? = status == "unavailable"
        def failed? = status == "failed"
        def runners = restoration.fetch(:runners)
        def reason = restoration[:reason]
      end
    end
  end
end
