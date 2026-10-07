module Rho
  class HostFollower
    # Durable events project the current execution and the host facts kept across turns.
    module Events
      private

        # Unarchive retains the old archive event and narrates no inverse.
        # Re-attaching must reconcile that event with the current row before
        # ending the new follower. A failed read leaves the cursor uncommitted
        # for the feed's ordinary retry; missing or forbidden ends via follow.
        def commit_end(payload)
          return if payload["reason"] == "archived" && !@context.fetch.archived?

          end_host
        end

        def commit_variant(payload)
          return unless payload["regenerating"] || payload["activated"]
          return unless @monitor.synchronize { payload["turn_public_id"] == @turn }

          # Selecting an older answer needs its current tasks, not the table
          # of the candidate we just left. Read only at this explicit boundary;
          # the existing feed retries a transient read without advancing.
          variant, run_row = selected_variant(payload) if payload["activated"]
          moved, had_text = @monitor.synchronize do
            previous_run = @run_public_id
            had_text = !@text.empty? || !@reasoning.empty?
            reset_execution
            @variant = payload["variant_public_id"]
            record_turn_ids(payload)
            if variant
              @status = variant.status
              @complete = TURN_TERMINAL_STATUSES.include?(@status)
            end
            restore_run_projection(run_row) if run_row
            [previous_run != @run_public_id, had_text]
          end
          if variant
            notify(Frame.new("stream_reset", { "reason" => "replaced" })) if had_text
            settle_text(payload["turn_public_id"], variant.content)
          end
          @on_turn&.call(self) if payload["activated"] && moved
        end

        def selected_variant(payload)
          variant = @context.turns.variants(payload["turn_public_id"]).find do |candidate|
            candidate.public_id == payload["variant_public_id"]
          end
          run_id = variant&.run_public_id
          [variant, run_id && @run_context.call(run_id).fetch]
        rescue CybrosAgent::Api::NotFound
          # Historical selections can name a turn deleted since the event.
          # Its absence must not be mistaken for the conversation ending.
          [nil, nil]
        end

        def restore_run_projection(run_row)
          @run_status = run_row.status
          @failure_reason = run_row.failure_reason
          @tasks = run_row.tasks.to_h do |task|
            [task.key, Task.new(task_key: task.key, kind: task.kind, status: task.status,
              error_key: task.error&.fetch("key", nil), failure_resolution: task.failure_resolution,
              after: task.after, on_failure: task.on_failure, model: task.model&.fetch("model", nil),
              finish_quality: task.finish_quality, refusal_category: task.refusal_category,
              model_change: task.model_change)]
          end
          attention = run_row.attention
          @attention = Attention.new(reason: attention.reason, blocked_task_keys: attention.blocked_task_keys) if attention
        end

        # View state hides presentation, not a live execution's identity or
        # its controls. Restore reads before publishing the new state so a
        # transient failure leaves this durable item for the feed to retry.
        def commit_view_state(payload)
          turn = payload.fetch("turn_public_id")
          state = @monitor.synchronize do
            remove_turn_frames(turn) if payload["visibility"] == "hidden" || payload["concealed"]
            next unless turn == @turn

            visibility = payload.fetch("visibility", @turn_visibility)
            concealed = payload.fetch("concealed", @turn_concealed)
            visible = visibility != "hidden" && !concealed
            [visibility, concealed, visible && !current_turn_visible?]
          end
          return if state.nil?

          visibility, concealed, recover = state
          visible = visibility != "hidden" && !concealed
          variant = restored_turn_variant(turn) if recover
          had_text = @monitor.synchronize do
            @turn_visibility, @turn_concealed = visibility, concealed
            next false if visible

            held = !@text.empty? || !@reasoning.empty?
            @text.reset
            @reasoning.reset
            @transcript_settled.delete(turn)
            @transcript_settling = nil
            held
          end
          notify(Frame.new("stream_reset", { "reason" => "replaced" })) if had_text
          settle_text(turn, variant.content) if variant
        end

        def restored_turn_variant(turn, variant_public_id: @variant)
          deck = @context.turns.variants(turn)
          current = deck.find { |candidate| candidate.public_id == variant_public_id }
          return if current && !TURN_TERMINAL_STATUSES.include?(current.status)
          # A completed candidate replaced by a later selection cannot seal
          # that new answer under the earlier execution's identity.
          return if current&.status == "completed" && !current.active?

          # A concealed candidate is absent from the complete live deck and
          # can only have been concealed after becoming terminal. The active
          # body may be an older candidate retained after a canceled sample.
          active = deck.active
          active if active && TURN_TERMINAL_STATUSES.include?(active.status)
        rescue CybrosAgent::Api::NotFound
          nil
        end

        def commit_deleted_turn(payload)
          changed, had_text = @monitor.synchronize do
            turn = payload.fetch("turn_public_id")
            @last_deleted_turn = turn
            remove_turn_frames(turn)
            next [false, false] unless turn == @turn

            held = !@text.empty? || !@reasoning.empty?
            @turns_seen << turn unless @turns_seen.include?(turn)
            reset_execution
            @turn = nil
            @turn_kind = nil
            [true, held]
          end
          return unless changed

          @gate&.cancel!
          notify(Frame.new("stream_reset", { "reason" => "replaced" })) if had_text
          @on_turn&.call(self)
        end

        # Both fields are current-Turn facts from the existing durable feed.
        # Exclusion from model context still permits timeline presentation.
        def current_turn_visible? = @turn_visibility != "hidden" && !@turn_concealed

        def past_turn?(turn) = turn && @turn.nil? && @turns_seen.include?(turn)

        def remove_turn_frames(turn)
          @frames.reject! { |frame| frame.dig("payload", "turn_public_id") == turn }
        end

        # THE ONE `turn_status` HANDLER. `status` is
        # OPTIONAL: present, the TURN moved — under the conversation lock by
        # settle, or under the run lock on a run host — and `complete`
        # follows it as a level; absent, a run-state note that moves only
        # the run's own word. `attention_reason` rides the run-locked write
        # and is absent when there is nothing to ask, so a resolved hold must
        # CLEAR the field: a stale ask is what a console renders as a call to act.
        #
        # A note or a settle for a turn that is not the current one is either
        # the NEXT turn — which starts the table over — or a late word about a
        # turn already left behind, which moves nothing.
        def commit_turn(payload)
          moved, settled, failed = @monitor.synchronize do
            next [false, false] unless admit_turn(payload)

            moved = record_turn_ids(payload)
            if payload.key?("run_status")
              @run_status = payload["run_status"]
              @failure_reason = payload["failure_reason"]
              @attention = nil if payload["attention_reason"].nil?
            end
            status = payload["status"]
            if status
              if @complete && !TURN_TERMINAL_STATUSES.include?(status)
                @transcript_settled.delete(@turn)
                @transcript_settling = nil
              end
              @status = status
              @failure_reason_key = payload["failure_reason_key"]
              @complete = TURN_TERMINAL_STATUSES.include?(status)
            end
            [moved, status && turn_settled?, status == "failed"]
          end
          @on_turn&.call(self) if moved
          return if @replay_truncated

          notify_failed_attention if failed && !settled
          settle_execution if settled
        end

        # The run announces its hold before the conversation projects the
        # failed turn. Tell the same attention observer again once that
        # durable turn is available, so its policy need not poll for it.
        def notify_failed_attention
          held = @monitor.synchronize { [@attention, @run_public_id] if @status == "failed" && @attention }
          @on_attention&.call(self, *held) if held
        end

        def settle_execution
          @gate&.cancel!
          refresh_children
          @on_complete&.call(self)
          @feed.stop if stopped_or_settled?
        end

        # Under the monitor: whether this item speaks about the turn the
        # table holds, starting the table over for a turn it has not seen.
        def admit_turn(payload)
          incoming = payload["turn_public_id"]
          return current_execution?(payload) if incoming.nil? || incoming == @turn
          # A run-state note for a turn already left behind, or a late settle
          # of one: nothing here moves for it.
          return false if @turns_seen.include?(incoming)
          return true if @turn.nil?
          return false if payload["status"].nil?

          reset_execution
          true
        end

        # Task keys are run-local; a background branch can still narrate
        # after another turn or candidate becomes current. The candidate
        # also identifies birth tasks before their run's first status note.
        def current_execution?(payload)
          turn = payload["turn_public_id"]
          return false if past_turn?(turn)

          variant = payload["variant_public_id"]
          run_id = payload["run_public_id"]
          (!turn || !@turn || turn == @turn) &&
            (!variant || !@variant || variant == @variant) &&
            (!run_id || !@run_public_id || run_id == @run_public_id)
        end

        def reset_execution
          @transcript_settled.delete(@turn)
          @transcript_settling = nil
          @tasks = {}
          @text.reset
          @reasoning.reset
          @status = "pending"
          @run_status = nil
          @failure_reason = nil
          @failure_reason_key = nil
          @run_public_id = nil
          @variant = nil
          @attention = nil
          @complete = false
        end

        # Under the monitor: the correlation ids the item carries; answers
        # whether either moved. The turn's KIND rides beside them: a new
        # turn takes the item's word (nil when the item carries none), an
        # item about the current turn that names it moves it, and a
        # run-state note without the key leaves it.
        def record_turn_ids(payload)
          moved = false
          turn = payload["turn_public_id"]
          if turn && turn != @turn
            @turn = turn
            @turns_seen << turn
            @turn_kind = payload["turn_kind"]
            @turn_visibility = "visible"
            @turn_concealed = false
            moved = true
          elsif payload.key?("turn_kind")
            @turn_kind = payload["turn_kind"]
          end
          @variant = payload["variant_public_id"] if payload["variant_public_id"]
          run_id = payload["run_public_id"]
          if run_id && run_id != @run_public_id
            @run_public_id = run_id
            @run_public_ids << run_id unless @run_public_ids.include?(run_id)
            moved = true
          end
          moved
        end

        # A `round_result` carries no `kind`; it must not erase the one the
        # task's own status event announced, or every settled model task
        # reads kind-less and nothing can tell a round from a tool call.
        # `after` likewise: an item that carries it is the newest word about
        # what the task hangs from — a consumer's grows as a branch forwards
        # onto it — and one that does not keeps what the row knew.
        # The TASK's item is the task's newest word: its switch note
        # (`model_change`) and nothing of the round that ended before it.
        def commit_task(payload)
          key = payload["task_key"]
          return if key.nil?

          @monitor.synchronize do
            next unless current_execution?(payload)

            existing = @tasks[key]
            after = Array(payload["after"])
            @tasks[key] = Task.new(
              task_key: key, kind: payload["kind"] || existing&.kind, status: payload["status"],
              on_failure: payload["on_failure"] || existing&.on_failure,
              error_key: payload["error_key"],
              failure_resolution: payload["failure_resolution"],
              after: after.empty? ? Array(existing&.after) : after,
              resolved_by: Hash.try_convert(payload["resolved_by"]) || existing&.resolved_by,
              model_change: Hash.try_convert(payload["model_change"])
            )
          end
        end

        # THE CLAIMANT ASKED FOR MORE TIME (executor.md "Extend"): kept on the
        # row so a watcher prints it once, beside the park it extends; a row
        # the follower has not seen yet is a late word about nothing.
        def commit_extension(payload)
          key = payload["task_key"]
          @monitor.synchronize do
            next unless current_execution?(payload)

            existing = @tasks[key]
            @tasks[key] = existing.with(extension_ms: payload["timeout_ms"]) if existing && key
          end
        end

        # A round ends on the EVENTS feed and its text settles on the
        # transcript one; clearing the preview here raced that settle and
        # made "print only the remainder" print the whole reply again. What
        # ends an answer is the next answer's key.
        # THE ROUND IS THE INVOCATION'S WORD, the task item before it the
        # task's: a declined round's invocation COMPLETED while its task
        # FAILED `model_refused`, so a round with no `error_key` keeps the
        # task's, and the switch note the task's item carried stands through
        # it. The round adds who answered and how it finished.
        def commit_round(payload)
          key = payload["task_key"]
          return if key.nil?

          @monitor.synchronize do
            next unless current_execution?(payload)

            existing = @tasks[key]
            @tasks[key] = Task.new(
              task_key: key, kind: existing&.kind, status: payload["status"], on_failure: existing&.on_failure,
              error_key: payload["error_key"] || existing&.error_key,
              failure_resolution: payload["failure_resolution"],
              after: Array(existing&.after), resolved_by: existing&.resolved_by,
              model_change: existing&.model_change, model: payload["model"],
              finish_quality: payload["finish_quality"], refusal_category: payload["refusal_category"]
            )
          end
        end

        # Kernel mail names its sourcing: the run and the key the
        # model saw. Kept across turns — the mail is the conversation's fact,
        # and the turn it answers for is already over. Every row names its
        # `origin`; every WRAPPED row is kept, with its speaker as the feed
        # carried it (`authored_by`, the sender stamp), so a
        # watcher prints `from:`. An `agent` row is mail only when it was SENT
        # from a conversation (the stamp): a bare one is a principal's word
        # posted directly — the person's own, through this daemon's agent
        # credential, or a peer app's. A child's reply is the one edge,
        # beside the turn settle, that changes the child tree.
        # A SCHEDULED ROW is kept
        # whatever its origin — a person's own timed word included — with
        # the `deliver_at` the kernel narrated, so a watcher prints
        # `scheduled:`; an untimed person row stays bare, as ever.
        def commit_mail(payload)
          scheduled = payload["deliver_at"]
          return unless scheduled || WRAPPED_ORIGINS.include?(payload["origin"])
          return if scheduled.nil? && payload["origin"] == "agent" && payload["sender_conversation_public_id"].nil?

          mail = { task_key: payload["task_key"], run_public_id: payload["run_public_id"],
                   input_public_id: payload["input_public_id"], origin: payload["origin"],
                   sender_conversation_public_id: payload["sender_conversation_public_id"],
                   authored_by: Hash.try_convert(payload["authored_by"]), deliver_at: scheduled }.compact
          @monitor.synchronize { @delivered_results << mail unless @delivered_results.include?(mail) }
          refresh_children if payload["origin"] == "child"
        end

        # THE CHILD TREE: the conversation's direct children,
        # each with the parent block's label and key, its answerer and
        # whether a reply runs there — read off the kernel on the two edges
        # a spawn or a reply can change it (the turn settle, a child's
        # reply), never per task. A read that fails keeps the last list: the
        # tree is a view, not the work.
        # THE CHILD EDGE: the ids new to the
        # list are told outside the monitor, as every callback is.
        def refresh_children
          return if @children.nil?

          children = @context.children.items.map do |child|
            { public_id: child.public_id, label: child.parent&.label, spawn_node_key: child.parent&.spawn_node_key,
              answering_user_public_id: child.answering_user_public_id, busy: child.busy? }.compact
          end
          added = @monitor.synchronize do
            known = @children.map { |child| child[:public_id] }
            @children = children
            children.map { |child| child[:public_id] } - known
          end
          @on_children&.call(self, added) unless added.empty?
        rescue StandardError => error
          @logger&.warn("host.children_unreadable", host: public_id, error_class: error.class.name,
                        error: CybrosAgent::Redaction.call(error.message))
        end

        # THE INPUT THE KERNEL REFUSED: the drain's `block` writes the input's
        # state and narrates it with the reason a person can act on. The
        # `run_held` narration rides the same item type with NO state write
        # — a transient hold, re-narrated per settle — and is not a block.
        def commit_blocked(payload)
          return if payload["blocked_reason"] == "run_held"

          blocked = { input_public_id: payload["input_public_id"], blocked_reason: payload["blocked_reason"] }
          @monitor.synchronize { @blocked = blocked }
        end

        # THE HANDOFF LANDED: a HOST item, whoever made it — this
        # daemon's own verb, a Human through the SDK — carrying the new
        # executor (absent after a reap), the previous and the caller. The
        # snapshot moves, and the daemon is told so the store row and the
        # next turn's lead follow.
        def commit_runner(payload)
          @monitor.synchronize { @default_runner = payload["executor_public_id"] }
          @on_default_runner_changed&.call(self, payload)
        end

        def commit_attention(payload)
          reason = payload["reason"]
          return if reason.nil?

          attention = Attention.new(reason: reason, blocked_task_keys: Array(payload["blocked_task_keys"]))
          @monitor.synchronize { @attention = attention if current_execution?(payload) }
          @on_attention&.call(self, attention, payload["run_public_id"])
        end
    end
  end
end
