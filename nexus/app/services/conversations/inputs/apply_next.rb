module Conversations
  module Inputs
    # Materializes the queue head into a Turn, in READ order (kernel origin
    # first, then arrival), in one transaction under the conversation lock;
    # content moves by seal-then-clone, zero bytes. A blocked head stops
    # the queue: skipping would reorder. A reply head becomes one model
    # call, or — when its declaring profile carries tools — a kernel loop
    # born running whose round one is the same assembled request; the
    # kernel's own receipt is such a head, and this is how it WAKES an idle
    # conversation. Either way the input's body is cloned onto the variant
    # as its `prompt`, the seed later history renders, and what the request
    # laid between history and it is sealed beside as its `preface`
    # (ContextAssembly::Preface), which history replays ahead of the seed.
    # Takes no loop lock but the newborn's own: a successor behind a live
    # loop wakes the converger, whose REPLACE arm stops it.
    class ApplyNext
      include ReplyMaterialization
      include CallbackBatch

      # Round one of a materialized turn; the fan and continuation keys
      # count on from it (ExpandRound::KEY_PREFIX).
      SEED_ROUND_KEY = "r1".freeze

      class << self
        def call(conversation_id:)
          new(conversation_id).call
        end

        # Applies heads until the lane stops being idle or the queue runs
        # dry; each application is its own transaction, so a mid-loop stop
        # loses nothing.
        def drain(conversation_id:)
          applied = 0
          loop do
            break unless call(conversation_id: conversation_id).accepted?

            applied += 1
          end
          applied
        end
      end

      def initialize(conversation_id)
        @conversation_id = conversation_id
      end

      def call
        outcome = nil
        # Preparation may insert a User/Speaker FK. Release the host first,
        # then resolve the actual head again under its lock. One retry covers
        # ordinary first use; continued edits leave the queue for its normal wake.
        2.times do
          @memory_preparation = nil
          outcome = materialize_next
          break unless @memory_preparation

          @memory_preparation.prepare_defaults
        end
        DrainJob.perform_later(@conversation_id) if @memory_preparation
        outcome
      end

      private

        def materialize_next
          outcome = ApplicationRecord.transaction(requires_new: true) do
            @conversation = Conversation.lock.find_by(id: @conversation_id)
            next Outcome.refused(:not_available) if @conversation.nil? ||
              @conversation.tombstoned?

            busy = ApplicationRecord.uncached do
              @conversation.turns.active.exists?
            end
            next Outcome.refused(:conversation_busy) if busy

            # DUE: a row before its time is not in the room — neither the head
            # nor a blocker — read against the database's clock, once. A
            # blocked row is always due: it blocked at materialization, which
            # only a due row reaches, and an edit that re-times it re-pends it
            # first (Update#apply).
            now = DatabaseClock.now
            candidates = @conversation.inputs
              .where(state: %w[pending blocked])
              .merge(Input.due(now))
              .in_read_order
            # Usually only the head can run; leave later prompts in the queue
            # instead of loading their potentially large assembly intent.
            head = ApplicationRecord.uncached { candidates.first }
            next Outcome.refused(:input_queue_empty) if head.nil?

            # The head is the first row in read order that is blocked (the
            # queue stops where it stands) or not held; under kernel-first a
            # held receipt would otherwise sit ahead of the one row that can
            # repair the hold — the person's post-settle word.
            tail = @conversation.turns.order(:position).last
            if head.state != "blocked" && held_behind?(head, tail)
              candidates = ApplicationRecord.uncached { candidates.to_a }
              head = candidates.find { |row| row.state == "blocked" || !held_behind?(row, tail) }
              next hold(candidates.first, tail.active_variant) if head.nil?
            end
            next Outcome.refused(:input_blocked) if head.state == "blocked"
            # THE FENCE, RE-READ: the door judged the author once, and a
            # scheduled word can outlive that judgement by a week. The same
            # predicate the door read, on the same row, on every principal's
            # head — one rule, no branch on `deliver_at` — parked with a name
            # the person can act on (delete, or restore the author's
            # standing). The kernel's rows are exempt as at the door.
            next block(head, :author_not_authorized) unless authorized?(head)

            # Resolve new sources before taking any originating Run lock. Mail
            # carries an existing capture and never performs a new selection.
            unless head.kernel_origin?
              context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
                principal: head.authoring_user, configuration: memory_selection(head),
                agent: head.execution_agent, execution: true)
              if context.defaults_missing?
                @memory_preparation = context
                # Roll back this savepoint so its host lock is released even
                # when a caller already owns an outer transaction.
                raise ActiveRecord::Rollback
              end
              refusal = context.selection_refusal
              next block(head, refusal) if refusal

              head.selected_memory_context = context.capture
            end
            callbacks = callback_batch(head, candidates)
            Runs::SourceWork.with_sources(callbacks.map(&:sender_run_public_id)) do |sources|
              delegation = Runs::Delegations.for_input(head)
              # A stopped dispatch never becomes a fresh runnable successor.
              # Materialization and exact cleanup share this Conversation lock.
              if Runs::SourceWork.stopped?(head.sender_run_public_id, sources[head.sender_run_public_id]) ||
                  Runs::Delegations.owner_stopped?(delegation)
                head.lock!
                Destroy.remove(head)
              else
                @delegation_lifetime = delegation ? "turn" : "conversation"
                @replaced_loop_id = tail&.live_run&.id
                if head.kind == "message"
                  materialize(head)
                else
                  # The head already passed its fence under this transaction's
                  # source locks. An ancestor cut may land between reads; do not
                  # re-read the head into an empty prefix after accepting it.
                  callbacks = [head] + callbacks.drop(1).take_while do |input|
                    !Runs::SourceWork.stopped?(input.sender_run_public_id, sources[input.sender_run_public_id])
                  end
                  materialize_callbacks(head, callbacks)
                end
              end
            end
          end
          outcome ||= Outcome.refused(:conversation_busy) if @memory_preparation
          # After commit, never under the lock: the REPLACE arm takes the loop,
          # and round one is minted by a scheduler pass like every round.
          if outcome.accepted? && @replaced_loop_id
            Turns::ConvergeJob.perform_later(@conversation_id, { "run_id" => @replaced_loop_id })
          end
          Runs::ScheduleJob.perform_later(@materialized_loop_id) if @materialized_loop_id
          outcome
        end

        # THE FIT WALL: the implicit fit overflowed. Internal to this lane
        # — it arms or slides, and never parks a head, because a request
        # under the window always goes.
        FIT_WALL = :history_exceeds_fit
        # The history cuts the fit wall reads: the window's tokens or the
        # seal's bytes crossed, or the candidate window's end.
        FIT_CUTS = %w[budget_exceeded candidate_limit].freeze

        # Input projects the role/access ceiling from stored values. Current
        # source availability belongs to this accepting application boundary.
        def memory_selection(input)
          selected = input.execution_memory_context
          return selected unless input.origin == "agent" && input.sender_run_public_id

          source = Run.find_by(public_id: input.sender_run_public_id)
          inherited = source ? MemoryDocuments::Context.inherit_from(source) : { "bindings" => [] }
          MemoryContext.inherit(configuration: selected, source: inherited,
            conversation_public_id: @conversation.public_id)
        end

        def authorized?(head) = head.kernel_origin? || @conversation.writable_by?(head.authoring_user)

        # The drain gate behind a hold: only a caller-authored word typed AFTER
        # the settle repairs a hold; a pre-hold row and kernel mail wait for a
        # person to move it. An ordinary failed summary turn is exempt: its
        # loop is nobody's hold to repair, so the head re-hits its wall
        # and blocks on size honestly instead of waiting for `rho retry` on a
        # kernel loop. Cost exhaustion remains repairable at the summary itself,
        # so its waiting input keeps the usual hold. Only a word addressed to the HELD answerer repairs:
        # a post-hold row to another agent would open that agent's turn and the
        # REPLACE arm would kill the repairable loop behind it — it waits like
        # a pre-hold row.
        def held_behind?(head, tail)
          variant = tail&.active_variant
          return false unless variant&.run&.needs_attention?
          if tail.kind == Compaction::Arm::SUMMARY_KIND
            return false unless variant.run.tasks.cost_limit_failures.exists?
          end

          head.sender_conversation_public_id.present? || head.created_at <= variant.updated_at ||
            head.answering_user_id != tail.answering_user_id
        end

        # No state write; narrated once per (head, settle) under a derived key.
        def hold(head, variant)
          Event::Append.call(
            host: @conversation,
            idempotency_key: Digest::UUID.uuid_v5(
              Digest::UUID::OID_NAMESPACE, "run_held:#{head.public_id}:#{variant.updated_at.to_f}"
            ),
            items: [{
              type: "input_blocked",
              payload: {
                "input_public_id" => head.public_id,
                "queue_position" => head.queue_position,
                "blocked_reason" => "run_held",
              },
            }]
          )
          Outcome.refused(:run_held)
        end

        def materialize(input, kind: input.kind)
          position = @conversation.timeline_position_head
          turn = Turn.create!(
            account: @conversation.account,
            conversation: @conversation,
            position: position,
            kind: kind,
            role: input.role,
            status: "completed",
            speaker: input.speaker,
            control_owner_user: input.authoring_user,
            # A message answers nothing: the conversation's answerer at
            # materialization.
            answering_user: @conversation.answering_user,
            visibility: input.visible_in_context ? "visible" : "excluded_from_context",
            origin: input.origin,
            input_public_id: input.public_id,
            callback_sources: [input.callback_source].compact,
            sender_conversation_public_id: input.sender_conversation_public_id,
            sender_run_public_id: input.sender_run_public_id,
            sender_task_key: input.sender_task_key,
          )
          variant = Variant.create!(
            account: @conversation.account,
            turn: turn,
            position: 0,
            status: "completed",
            source: "manual",
          )
          adopt_content(input, variant)
          turn.update!(active_variant: variant)

          queue_position = input.queue_position
          @conversation.record_scheduled_turn(input, turn)
          input.destroy!

          @conversation.update!(
            timeline_position_head: position + 1,
            context_revision:
              @conversation.context_revision + (turn.visibility == "visible" ? 1 : 0),
            last_activity_at: Time.current,
          )
          narrate(turn, variant, queue_position)
          Outcome.accepted(turn)
        end

        def adopt_content(input, variant)
          body = input.content_body
          return if body.nil?

          body.seal
          clone = ContentBodies::CloneSealed.call(source: body, owner: variant, role: "content")
          variant.update_content_preview(clone.effective_text)
        end

        # Selection re-resolves at materialization, so a catalog change
        # while queued answers honestly. A principal's selection refusal parks
        # the head for correction; kernel mail keeps a recoverable loop and
        # its sealed prompt even before a model becomes available.
        def materialize_reply(input)
          # The omitted-inline path resolves the standing profile here once.
          # All later work, including regeneration and kernel mail, uses this
          # execution's declaration rather than a subsequent profile edit.
          input.agent_configuration ||= AgentConfiguration.capture(input.execution_agent)
          input.agent_configuration.executor_contexts = input.executor_contexts if input.agent_configuration && input.executor_contexts
          @tool_assembly = input.tool_assembly
          return park(input, @tool_assembly.refusal) if @tool_assembly.refused?

          environment = @tool_assembly.environment
          if environment
            context = MemoryDocuments::Context.new(workspace: @conversation.workspace, conversation: @conversation,
              principal: input.authoring_user, configuration: input.execution_memory_context, agent: input.execution_agent,
              execution: true)
            skills = if environment.key?("skills")
              # A receipt keeps its frozen catalog, but a receiver's narrowed
              # memory roots must also remove those descriptions from the seed.
              roots = context.bindings.map(&:name)
              environment.fetch("skills").select do |entry|
                entry["executor_public_id"] || roots.include?(entry.fetch("source"))
              end
            else
              Runs::Skills::Catalog.for(tools: @tool_assembly.definitions,
                address: Executor.address_for(input.execution_agent), context: context)
                .map { |entry| entry.to_h.stringify_keys }
            end
            @tool_assembly = @tool_assembly.with(environment: environment.merge("skills" => skills))
          end

          selection, selection_refusal, prepared = resolve_selection(input)
          return materialize_unavailable_result_delivery(input) if selection_refusal && input.kernel_origin?
          return park(input, selection_refusal) if selection_refusal

          # THE PROVIDER'S OWN NUMBER FIRST: the last reported usage plus
          # what this reply appends, before any counting.
          over = over_usage(input, selection)
          if over
            armed = arm(input, selection, Compaction::Trigger.usage(input, overshoot: over))
            return Outcome.refused(:conversation_busy) if armed.accepted?
          end

          result, refusal = attempt_reply(input, selection, prepared: prepared)
          return Outcome.refused(refusal) if refusal == CALLBACK_FIT_REFUSAL
          # THE FIT IS THE WALL: with no stated budget the assembly fits
          # history to the window, and once the timeline crosses the fit
          # every reply would drop the oldest turn — a sliding window that
          # re-writes the whole history tail at cache-write rates with no
          # read on it, on every turn. Codex and claude-code compact (one
          # cut, then a stable head); so does this lane: the overflow arms
          # the summary the size walls arm, and the head waits behind it.
          # Traces are history and go with their turns: none is cut to make
          # room, and no request is re-sent without them. Only when no
          # summary can be armed (the author's `off`; a summary that itself
          # overflows the fit) does the trimmed request send — the slide as
          # the lesser fallback, trimmed to both the window and the seal's
          # bytes, narrated as `context_trimmed` as it always was.
          if refusal == FIT_WALL
            armed = arm(input, selection, Compaction::Trigger.wall(input))
            return Outcome.refused(:conversation_busy) if armed.accepted?

            Rails.logger.info(
              "event=history_fit_slid input=#{input.public_id} reason=#{armed.outcome}"
            )
            result, refusal = attempt_reply(input, selection, slide: true)
          end
          if refusal && size_wall?(refusal)
            # The one refusal this lane can repair: the input stays pending
            # behind the summary turn — the active turn, as any — and the
            # converger drains again once its loop settles. Under raw the
            # kernel owns no history and the head blocks saying so.
            armed = arm(input, selection, Compaction::Trigger.wall(input))
            return Outcome.refused(:conversation_busy) if armed.accepted?
            return park(input, armed.outcome) if armed.outcome == Compaction::Arm::RAW_REFUSAL
          end
          return park(input, refusal) if refusal

          result
        end

        # A hard refusal parks a principal's head blocked — a person's word
        # or a peer's `send` — since the edit and the delete are its repair
        # paths. Both are closed on a kernel-origin row, so a receipt the
        # drain cannot serve DEGRADES instead: it lands as a completed
        # `message` turn the next reply reads, and the queue moves.
        def park(input, reason)
          return block(input, reason) unless input.kernel_origin?

          Rails.logger.info(
            "event=kernel_input_degraded input=#{input.public_id} reason=#{reason}"
          )
          materialize(input, kind: "message")
        end

        def arm(input, selection, trigger)
          Compaction::Arm.call(
            conversation: @conversation, selection: selection, trigger: trigger, raw: input.raw?
          )
        end

        # Occupancy = the newest provider-reported `input_tokens` on this
        # timeline plus the turns since it and this prompt, priced as
        # assembly prices text. A raw head reads no history, so it has no
        # occupancy to arm on. Answers the overshoot past the window, else nil.
        def over_usage(input, selection)
          return nil if input.raw?

          limit = selection.capabilities.limits.planning_input_bound
          return nil if limit.nil?

          reading = Compaction::LastUsage.for_conversation(@conversation)
          return nil if reading&.record&.input_tokens.nil?

          profile = selection.execution_profile
          tail = [input.content_body&.effective_text, *texts_since(reading.since_position)]
          # The counted answer — its reply and the reasoning the next request
          # replays — is its own `output_tokens`, reasoning included on every
          # shipped wire.
          occupancy = reading.record.input_tokens + reading.record.output_tokens.to_i +
            tail.sum { |text| ContextAssembly::FillCost.call(text, profile) }
          Compaction::Overshoot.tokens(occupancy - limit) if occupancy > limit
        end

        # The turns materialized after the one the provider last counted —
        # each as what history renders of it: its preface, its seed and its
        # content.
        def texts_since(position)
          turns = @conversation.timeline.entries(surface: :assembly, after_position: position).map(&:turn)
          ContentBody.where(variant_id: turns.filter_map(&:active_variant_id),
            role: ["content", "prompt", ContextAssembly::Preface::ROLE])
            .map(&:effective_text)
        end

        # The only two walls a summary would touch: the window's exact count
        # and the seal's bytes. Under the author's `off` the slide trims to
        # both, so a request the seal still refuses is one whose own input
        # is too large, and it blocks the head as any raw oversize does.
        def size_wall?(refusal)
          [:estimated_input_exceeds_model_limit, Nexus::SizeBounds::REJECTION].include?(refusal)
        end

        def prepare_reply(input, selection, slide: false)
          compiled, assembled, refusal, uploads = compile_input(input, selection, slide: slide)
          return [nil, assembled, refusal] if refusal

          normalized = ModelSelection::Workloads.normalize_workload_input(
            selection: selection, input: compiled, uploads: uploads)
          return [nil, assembled, normalized.refusal] unless normalized.accepted?

          [normalized, assembled, ModelSelection::Recovery.context_refusal(selection, normalized.value.value)]
        end

        def attempt_reply(input, selection, slide: false, prepared: nil)
          normalized, assembled, refusal = prepared || prepare_reply(input, selection, slide: slide)
          return [nil, refusal] if refusal

          reply_refusal = nil
          result = nil
          ApplicationRecord.transaction(requires_new: true) do
            result = materialize_head(input, selection, normalized, assembled)
            unless result.accepted?
              reply_refusal = result.outcome
              raise ActiveRecord::Rollback
            end
          end
          [result, reply_refusal]
        end

        # `assembled` compiles the prompt from what the kernel holds; `raw` —
        # the input's word or its profile's — sends the input's body
        # verbatim, bounds and window gate still applying. Answers
        # `[messages, assembled, refusal, uploads]` — `assembled` the
        # assembly (its history's evidence, its preface to seal), nil under
        # raw — and the PLACED rows: under
        # raw the body's own joins (the door bound what the entries placed,
        # never enriched, so a row the wire cannot take is the InferenceRequest's
        # blocked head); assembled, what placement kept native. `slide`
        # admits an assembly trimmed past the IMPLICIT fit (the wall's
        # fallback); without it that overflow answers FIT_WALL.
        def compile_input(input, selection, slide: false)
          if input.raw?
            body = input.content_body
            entries = body&.entry_payloads
            return [nil, nil, :missing_input] if entries.blank?

            begin
              value = Nexus::InputEntries.from(
                entries: entries, workload: "text_generation"
              )
              [InferenceRequests::CoerceTextMessages.call(value), nil, nil, body.content_uploads.to_a]
            rescue ArgumentError, KeyError, Enumerable::SoleItemExpectedError
              # The raw grammar is the caller's to satisfy — a mixed or
              # malformed list blocks with the grammar's own refusal.
              [nil, nil, :invalid_input]
            end
          else
            # The words as the model reads them: bare for the conversation's
            # own voices, in the speaker envelope for anyone else's row — the
            # same rendering later history gives the seed.
            prompt = ContextAssembly::SpeakerEnvelope.for_input(input)
            # The addressee's template of THIS day: the door validated
            # against the row of its own, and a re-declaration between
            # the two parks the head by name.
            template = input.assembly_template
            refusal = template.turn_refusal(
              variables: input.context_options["variables"], inline: input.context_options["inline"]
            )
            return [nil, nil, refusal] if refusal

            history = input.context_options["history"] || {}
            budget = ContextAssembly::HistoryBudget.call(
              share: history["token_budget_share"] || template.history_share,
              limits: selection.capabilities.limits
            )
            return [nil, nil, budget.outcome] unless budget.accepted?

            assembled = ContextAssembly.assemble(
              memory_context: input.execution_memory_context,
              conversation: @conversation,
              principal: input.authoring_user,
              prompt: prompt,
              history_max_entries: history["max_entries"],
              history_token_budget: budget.value,
              profile: selection.execution_profile,
              limits: selection.capabilities.limits,
              reasoning: replay_ask(input, selection),
              inline: input.context_options["inline"],
              execution_agent: input.execution_agent,
              agent_configuration: input.agent_configuration,
              # And whose turn this is: the addressee's — another agent's earlier
              # reply reads as its message, not as this model's own.
              answerer: input.answering_user,
              # The input's pictures in part order, placed per part against
              # THIS turn's resolved selection: native on a row that takes
              # them, the index line on one that cannot.
              attachments: input.content_body&.upload_parts || [],
              carries: ContextAssembly::AttachmentLine.carries_for(selection),
              template: template,
              variables: input.context_options["variables"],
              # THE TOOL SET THIS TURN WILL DECLARE: the seed round's own
              # expression — the declaring profile's set narrowed to the
              # input's `tool_names` — so the skills block renders exactly
              # when the round carries `skill`.
              tools: @tool_assembly.definitions,
              environment: @tool_assembly.environment
            )
            callback_refusal = callback_history_refusal(assembled, template)
            return [nil, assembled, callback_refusal, nil] if callback_refusal
            return [nil, assembled, FIT_WALL, nil] if fit_wall?(assembled.history, budget.value, slide)

            [assembled.messages, assembled, nil, assembled.uploads]
          end
        end

        # A stated budget (the per-turn share or the template's) is the
        # caller's own bound: trimming to it is what was asked, and the
        # slide is theirs. With none stated the fit is the kernel's, and
        # its overflow is the wall — the window's tokens, the seal's bytes,
        # or a history longer than the candidate window, each of which
        # would otherwise slide a turn off the head on every reply.
        def fit_wall?(history, stated_budget, slide)
          !slide && stated_budget.nil? && FIT_CUTS.include?(history.skipped_reason)
        end

        # The caller's replay policy wins; the kill-switch silences the
        # default; otherwise the kernel's (Replay::DEFAULT_MODE).
        def replay_ask(input, selection)
          mode = input.context_options.dig("reasoning_replay", "mode")
          mode ||= "none" if @conversation.reasoning_replay_downgraded_at
          ContextAssembly::Replay.from_selection(selection, mode: mode)
        end

        def resolve_selection(input, model: input)
          if model.provider_id.blank? || model.model_ref.blank?
            return [nil, :model_selection_missing]
          end

          submitted = Nexus::SubmittedModelSelection.new(
            model: "#{model.provider_id}/#{model.model_ref}",
            reasoning_effort: model.reasoning_effort,
            reasoning_enabled: model.reasoning_enabled
          )
          prepared = nil
          resolved = AnswerEngine.resolve(
            account: @conversation.account,
            submitted: submitted,
            configuration: InferenceRequests::CoerceConfiguration.call(input.request_options),
            model_selection: input.execution_model_selection,
            fallback_models: input.execution_fallback_models
          ) do |candidate|
            refusal = ModelSelection::Recovery.tools_refusal(candidate, @tool_assembly.definitions)
            next refusal if refusal

            prepared = prepare_reply(input, candidate)
            prepared.last
          end
          @model_skips = resolved.skips
          @model_change = if resolved.resolved? && "#{resolved.selection.provider_id}/#{resolved.selection.model_ref}" != submitted.model
            Runs::ModelFallback.from_selection(resolved.selection, reason: @model_skips.first.fetch("reason"))
              .narration(submitted.model).fetch("model_change")
          end
          resolved.resolved? ? [resolved.selection, nil, prepared] : [nil, resolved.refusal]
        end

        # Authored trailing work needs the same Run owner as declared tools.
        # Every other principal's head remains one model call.
        def materialize_head(input, selection, normalized, assembled)
          if input.kernel_origin? || input.steps.present? || input.execution_configuration&.tool_approval_required?
            materialize_loop(input, selection, normalized.value.value, normalized.value.uploads, assembled)
          else
            create_reply(input, selection, normalized, assembled)
          end
        end

        # BLOCKED is a durable, narrated state — never a silent drop. The
        # head stays at its position (FIFO holds behind it) with the reason
        # a sender or an edit can act on.
        def block(input, reason)
          input.update!(state: "blocked", blocked_reason: reason.to_s.first(64))
          # A fresh append key, deliberately: the input's own id already keyed
          # its acceptance, and an edit may unblock and re-block — each block
          # is its own fact.
          Event::Append.call(
            host: @conversation,
            items: [{
              type: "input_blocked",
              payload: {
                "input_public_id" => input.public_id,
                "queue_position" => input.queue_position,
                "blocked_reason" => input.blocked_reason,
              },
            }]
          )
          Outcome.refused(:input_blocked)
        end

        # Materialization names its original candidate in one event. Later
        # regenerations never change what this input started.
        def narrate_reply(turn, variant, queue_position, history, run)
          items = [
            {
              type: "input_materialized",
              payload: TurnProjection.materialization(turn, variant, run)
                .transform_keys(&:to_s).merge("queue_position" => queue_position),
            },
            {
              type: "turn_created",
              payload: {
                "turn_public_id" => turn.public_id,
                "position" => turn.position,
                "kind" => turn.kind,
                "role" => turn.role,
                "status" => turn.status,
                "visibility" => turn.visibility,
                "answering_user_public_id" => turn.answering_user.public_id,
              },
            },
            {
              type: "turn_status",
              payload: {
                "turn_public_id" => turn.public_id,
                "turn_kind" => turn.kind,
                "variant_public_id" => variant.public_id,
                "status" => "running",
                "run_public_id" => run&.public_id,
                "model_skips" => @model_skips&.presence, "model_change" => @model_change,
              }.compact,
            },
          ]
          # Narrated only when something was left out: an untrimmed
          # assembly's evidence is the sealed request.
          if history && history.skipped_count.positive?
            items << {
              type: "context_trimmed",
              payload: {
                "turn_public_id" => turn.public_id,
                "history_selected" => history.selected_count,
                "history_skipped" => history.skipped_count,
                "history_skipped_reason" => history.skipped_reason,
              },
            }
          end
          Event::Append.call(
            host: @conversation,
            idempotency_key: turn.public_id,
            items: items
          )
        end

        # One append, two items — the acceptance's counterpart, keyed by the
        # turn so the materialization has its own one-per-turn replay
        # contract.
        def narrate(turn, variant, queue_position)
          Event::Append.call(
            host: @conversation,
            idempotency_key: turn.public_id,
            items: [
              {
                type: "input_materialized",
                payload: TurnProjection.materialization(turn, variant)
                  .transform_keys(&:to_s).merge("queue_position" => queue_position),
              },
              {
                type: "turn_created",
                payload: {
                  "turn_public_id" => turn.public_id,
                  "position" => turn.position,
                  "kind" => turn.kind,
                  "role" => turn.role,
                  "status" => turn.status,
                  "visibility" => turn.visibility,
                  "answering_user_public_id" => turn.answering_user.public_id,
                },
              },
            ]
          )
        end
    end
  end
end
