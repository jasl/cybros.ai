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

      def scheduled_jobs = ScheduledJobsContext.new(dispatch: @dispatch, path: "#{path}/scheduled_jobs")

      # DURABLE MEMORY — this conversation's named bindings, or its default
      # scopes (its own, its workspace's, the caller's `user/`).
      # See MemoryContext for why a conversation writes memory over HTTP
      # where an agent loop calls a tool.
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

      # THE HANDOFF: the next round's runner-kind calls land on the
      # named runner, and every dispatched call nobody has claimed is
      # re-addressed NOW with its clock re-armed; a claimed call settles
      # where it started. A whole replacement of one binding, so PUT on
      # the nested singular resource. 404 `runner_not_found`, 409
      # `runner_not_eligible` (the message names why), 403 for a caller
      # that does not run this host; the same id is a plain 200. Answers
      # the conversation carrying the binding it now has.
      def bind_runner(executor_public_id:)
        binding = { "executor_public_id" => required_string(executor_public_id, "executor_public_id") }
        answer = @dispatch.call("#{path}/runner", method: :put, body: { "runner" => binding })
        shape(Conversation, answer, "conversation")
      end

      # THE ACCESS CARRIER'S LATER CHANGE: a WHOLE replacement of the
      # default and the named entries, PUT on the nested singular resource
      # — the handoff's shape, idempotent by value with no receipt. The
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
      # `side: true` is THE SIDE CONVERSATION: no turn is named — the
      # kernel forks at the live head from the parent's newest SETTLED turn,
      # even while a later turn runs, and the child renders the inherited
      # history behind a boundary item with the parent's prefix bytes
      # shared. A turn named beside `side` is not read. A side is never
      # forked again (422 `side_of_side`), never archived, and `delete`
      # reaps it at once.
      #
      # The answer's `world` is the kernel's fact for the FORK POINT:
      # the earliest-claimed runner-addressed write-kind call strictly above
      # the turn in the source's reach — claim order, not task creation order;
      # every candidate and every
      # concealed turn counted, the world being physical — so its
      # `checkpoint` names the tree before the successors' work;
      # `untouched` when nothing above it wrote; a replay answers the
      # same value. The child's `conversation.runner` is on the same
      # answer: the two facts a rewind compares.
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
          world: shape(World, result.body, "world")
        )
      end

      # REWIND TO A TURN: the SDK's composition, never a kernel verb —
      # FORK at the turn, read the fork answer's `world`, then ask the
      # CHILD's bound runner to restore the files to that point through a
      # request loop, and poll. Fork FIRST: a
      # fork creates no turn and nothing runs in the child until an input,
      # so a refusal costs nothing and no source ever stands on a rewound
      # tree — every fork refusal (`not_found`, `side_of_side`,
      # `variant_not_forkable`, `fork_too_large`, an idempotency mismatch,
      # an archived source) raises HERE, before any restore.
      #
      # The answer's `world` says what happened to the files, and the fork
      # is made either way: `untouched` (nothing wrote above the turn),
      # `kept` (`world: false` — the fork alone), `restored` (the tree put
      # back, with the `undo` a later call could replay, and `outside` /
      # `ignored` naming the paths it could not reach), `unavailable`
      # (`runner_mismatch` — another runner holds the tree, or
      # `no_checkpoint` — the runner kept none) or `failed` (the restore
      # ran and could not: `checkpoint_unknown`, `tool_timeout`, …). The
      # kernel compares nothing; the two facts a rewind reads — the fork
      # point's `world` and the child's bound `runner` — ride ONE fork
      # answer.
      #
      # `world: false` forks and restores nothing. `idempotency_key` is the
      # FORK's: a second rewind with the same key replays the child (the
      # same fork-point `world` off the receipt) and runs a second restore
      # of the same tree, whose undo is recorded afresh. `poll`/`patience`
      # bound the restore's own request; `approval_rules` shape it (the
      # relay's shell). `restore_guard` runs after checkpoint resolution;
      # a refusal keeps the child and reports a failed world outcome.
      def rewind(turn_public_id:, idempotency_key:, variant_public_id: UNSET, title: UNSET,
                 world: true, poll: AgentLoopContext::DEFAULT_REQUEST_POLL_SECONDS,
                 patience: nil, approval_rules: UNSET, restore_guard: nil)
        required_string(idempotency_key, "idempotency_key")

        forked = fork(idempotency_key:, turn_public_id:, **fields(variant_public_id:, title:).transform_keys(&:to_sym))
        Rewound.new(
          conversation: forked.conversation, replayed: forked.replayed,
          fork_point: forked.world,
          world: rewind_outcome(forked, world:, poll:, patience:, approval_rules:, restore_guard:)
        )
      end

      # THE RESTORE HALF OF A REWIND, ON ITS OWN:
      # put the tree back to a fork point's `world` — the kernel's fact
      # off a fork answer or a variant's deck — through `runner`, the
      # executor that holds the tree (a conversation's bound
      # `runner.executor_public_id`). The SDK's derivation over two
      # strings and, on a cache miss, ONE more request; the kernel judges
      # nothing. The answer is the outcome Hash `rewind` reports:
      # `untouched` (nothing wrote above the point), `unavailable`
      # (`runner_mismatch` — another runner or none holds the tree;
      # `no_checkpoint` — the runner kept none, `skipped` saying why when
      # it said), `restored` (with the `undo` and what it could not reach)
      # or `failed` (the restore failed or the application guard refused it).
      # A regenerate that
      # restores BEFORE the kernel's door composes this with its own
      # refusals; `rewind` composes it behind the fork. An optional
      # `restore_guard` receives (runner, resolved checkpoint), returning
      # nil to proceed or a failure reason to refuse before any restore.
      def restore_world(world, runner:, poll: AgentLoopContext::DEFAULT_REQUEST_POLL_SECONDS,
                        patience: nil, approval_rules: UNSET, restore_guard: nil)
        return { status: "unavailable", reason: world.reason } if world.unavailable?
        return { status: "untouched" } if world.untouched?
        return { status: "unavailable", reason: "runner_mismatch" } if world.runner != runner

        captured = world.checkpoint_hash ? world.checkpoint : restorable_checkpoint(world, runner, poll:, patience:)
        return unavailable_for(world) if captured.nil?

        reason = restore_guard&.call(runner, captured)
        return { status: "failed", reason: reason } if reason

        restore_request(runner, captured, poll:, patience:, approval_rules:)
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
      def estimate_input(model:, prompt: UNSET, reasoning_effort: UNSET,
                         configuration: UNSET, history: UNSET,
                         reasoning_replay: UNSET, inline: UNSET, render: UNSET,
                         to: UNSET, variables: UNSET, template: UNSET)
        body = fields(
          model: fields(model:, reasoning_effort:), prompt:, configuration:, history:,
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
      # loop-backed turn — one kernel loop whose only task is the
      # summarizer — and settles through the same converger as any other.
      def compact(model: UNSET, reasoning_effort: UNSET)
        shape(ConversationCompaction, @dispatch.call("#{path}/compaction", method: :post,
            body: { "compaction" => fields(model:, reasoning_effort:) }, success: 202))
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
      # it terminalizes; both route by `turn_public_id`. A loop-backed
      # turn's rounds settle here too, `round` and `call` under `task_key`
      # with the loop's id beside the turn's. A delta that never arrives
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

        # What a rewind reports for the files: `untouched` before `kept`
        # (a fork alone of an untouched point restored nothing either
        # way), then the restore proper on the CHILD's bound runner.
        def rewind_outcome(forked, world:, poll:, patience:, approval_rules:, restore_guard:)
          return { status: "untouched" } if forked.world.untouched?
          return { status: "kept" } unless world

          restore_world(forked.world, runner: forked.conversation.runner&.executor_public_id,
            poll:, patience:, approval_rules:, restore_guard:)
        end

        # The runner declined (a `{skipped}` fact) is FINAL; a missing
        # `checkpoint` (a raised hook, a placeholder value) ASKS the store.
        def restorable_checkpoint(world, runner, poll:, patience:)
          return nil unless world.skipped.nil?

          store_checkpoint(runner, world.loop, poll:, patience:)
        end

        def unavailable_for(world)
          return { status: "unavailable", reason: "no_checkpoint", skipped: world.skipped } unless world.skipped.nil?

          { status: "unavailable", reason: "no_checkpoint" }
        end

        # THE CACHE MISS ASKS THE TRUTH (K-s3): `checkpoints {loop}` through
        # a request loop; a present checkpoint including its store, else
        # nil. A runner that announces no store fails the request → nil.
        def store_checkpoint(runner, loop, poll:, patience:)
          return nil if runner.nil? || loop.nil?

          detail = request_loop(runner, "checkpoints", { "loop" => loop }, poll:, patience:)
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
          detail = request_loop(runner, "world_restore", input,
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

        def request_loop(runner, tool, input, poll:, patience:, approval_rules: UNSET)
          AgentLoopsContext.new(dispatch: @dispatch, workspace_public_id: @workspace_public_id)
            .request(runner_executor_public_id: runner, tool: tool, input: input,
              idempotency_key: SecureRandom.uuid, approval_rules: approval_rules)
            .request_result(poll: poll, patience: patience)
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

      Forked = Data.define(:conversation, :replayed, :world) do
        def replayed? = replayed

        def public_id = conversation.public_id
      end

      # WHAT A REWIND ANSWERS: the child (`conversation`), whether the
      # fork replayed, the kernel's FORK-POINT fact verbatim (`fork_point`,
      # a `World`), and the SDK's OUTCOME (`world`, a Hash keyed by
      # `status`) — the two are different things: one is what the kernel
      # holds, one is what the restore did. `restored?` and its siblings
      # read the outcome's `status`.
      Rewound = Data.define(:conversation, :replayed, :fork_point, :world) do
        def replayed? = replayed
        def public_id = conversation.public_id

        def status = world[:status]
        def restored? = status == "restored"
        def untouched? = status == "untouched"
        def kept? = status == "kept"
        def unavailable? = status == "unavailable"
        def failed? = status == "failed"

        def checkpoint = world[:checkpoint]
        def undo = world[:undo]
        def reason = world[:reason]
      end
    end
  end
end
