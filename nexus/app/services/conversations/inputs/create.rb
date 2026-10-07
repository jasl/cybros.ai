module Conversations
  module Inputs
    # The one input door, over a host: the row is the message and the
    # waiting room, acceptance never touches the timeline. `host` is the
    # row whose door was knocked.
    class Create
      # `tool_names` is the turn's tool subset, nil for the declaring
      # profile's whole set; `approval_mode` the turn's tightening of the
      # profile's word, nil for the word itself; `instructions` is `raw`'s
      # system field, nil on an assembled turn. `answering_user_public_id` is
      # the ADDRESSEE: who answers this turn, as `@handle` or a public id —
      # the create door's word on the wire, `to:` in the SDK — nil for the
      # host's answerer. The sender fields are the stamped constructors', never a
      # controller's: the `origin` word (nil = derived on the row from the
      # author's kind) and the sender stamp ride the row; a sent request also
      # retains its sending loop and task key: that execution owns cancellation
      # and the reply surface, and only the original spawn request may settle
      # its await. `delegation` is the kernel's completion row, whose publication
      # UUID and this accepted input must commit together. `attachments` is the
      # canonical upload ids a person's message carries beside its `text`, in order —
      # the door composes the one `{role, parts}` entry from the two; nil when
      # the message carries none (raw `entries` place their own parts).
      # `deliver_at` is the caller's "not before" as ONE resolved Time — the
      # boundary parsed `deliver_at` or `deliver_in` through `DeliverAt` — nil
      # for now; the conversation host's alone, never the kernel's.
      Command = Data.define(:host, :acting_user, :kind, :role, :entries,
        :visible_in_context, :delivery_mode, :context_mode, :context_options,
        :expected_context_revision, :expected_tail_turn_public_id, :expected_steering_run_public_id,
        :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled, :request_options, :tool_names, :approval_mode,
        :instructions, :answering_user_public_id, :speaker_public_id, :attachments, :deliver_at, :steps,
        :origin, :sender_conversation_public_id, :run_public_id, :task_key, :delegation, :callback_result) do
        def initialize(reasoning_enabled: nil, tool_names: nil, approval_mode: nil, instructions: nil, answering_user_public_id: nil,
                       attachments: nil, deliver_at: nil, steps: nil, speaker_public_id: nil, expected_steering_run_public_id: nil,
                       origin: nil, sender_conversation_public_id: nil, run_public_id: nil,
                       task_key: nil, delegation: nil, callback_result: nil, **) = super

        # Kernel mail: a user-role row that always QUEUES — never a steer,
        # so a running turn finishes first and an idle conversation is woken
        # by it — sent as the loop's creator under the loop's own
        # conversation as the sender. A receipt is a `direct_reply` on the
        # surface the mailing loop read off itself (the model selection, its
        # tightening, its narrowed tools); the flat `message` shape stays
        # for a notice with nothing to wake. Its addressee rides the ONE
        # member: the mailing loop's own answerer — a task A started answers
        # to A's turn, never to the conversation's default — and the door
        # never judges the kernel's mail for eligibility.
        def self.kernel(host:, acting_user:, entries:, origin:, sender_conversation_public_id:,
                        run_public_id: nil, task_key: nil, kind: "message",
                        provider_id: nil, model_ref: nil, reasoning_effort: nil, reasoning_enabled: nil,
                        tool_names: nil, approval_mode: nil, answering_user_public_id: nil, callback_result: nil)
          # REQUIRED to be the kernel's own word (the Tasks::Append
          # precedent): an unlabelled kernel writer would be a silent grant
          # past the door's level.
          raise ArgumentError, "origin must be one of #{ConversationInput::KERNEL_ORIGINS.join("|")}" unless
            ConversationInput::KERNEL_ORIGINS.include?(origin)

          new(host:, acting_user:, kind:, role: "user", entries:,
              visible_in_context: true, delivery_mode: "queue", context_mode: nil, context_options: nil,
              expected_context_revision: nil, expected_tail_turn_public_id: nil,
              provider_id:, model_ref:, reasoning_effort:, reasoning_enabled:, request_options: nil,
              tool_names:, approval_mode:, answering_user_public_id:,
              origin:, sender_conversation_public_id:, run_public_id:, task_key:, callback_result:)
        end

        # A PRINCIPAL'S row carrying the kernel's stamps: a peer's `send`
        # and the spawn brief — sent AS the sender, whose kind the row
        # records (`agent`, or `person` for a human), never as the
        # recipient's answerer and never through `kernel`. Judged as the
        # caller it is: the level, the bin, the bound. Its model selection is
        # THE INITIATOR'S: the ladder's last rung, read only when the
        # addressee has no preset and no history here.
        def self.sent(host:, acting_user:, entries:, sender_conversation_public_id:,
                      delivery_mode: "queue", kind: "message", run_public_id: nil, task_key: nil,
                      provider_id: nil, model_ref: nil, reasoning_effort: nil, reasoning_enabled: nil,
                      tool_names: nil, approval_mode: nil, answering_user_public_id: nil, deliver_at: nil,
                      delegation: nil)
          new(host:, acting_user:, kind:, role: "user", entries:,
              visible_in_context: true, delivery_mode:, context_mode: nil, context_options: nil,
              expected_context_revision: nil, expected_tail_turn_public_id: nil,
              provider_id:, model_ref:, reasoning_effort:, reasoning_enabled:, request_options: nil,
              tool_names:, approval_mode:, answering_user_public_id:, deliver_at:,
              origin: nil, sender_conversation_public_id:, run_public_id:, task_key:, delegation:)
        end

        # The kernel's own act, BY NAME: what the door's level and the bin
        # exempt. A row with an origin outside the kernel's set is a caller's.
        def kernel? = ConversationInput::KERNEL_ORIGINS.include?(origin)

        # A principal's stamped row (`sent`): a peer's `send` or a brief —
        # the sender's stamp on a row that is not the kernel's.
        def sent? = !kernel? && sender_conversation_public_id.present?
      end

      # Attachments are refused on steers: the public steer path carries
      # text only. Queue an attachment-bearing input so it lands through
      # the input body's normal placement and upload-binding path.
      NOT_STEERABLE = :attachments_not_steerable
      # A STEER TAKES NO TIME: a steer binds NOW to the reply in flight; a
      # future steer has nothing to bind to. Refused by name before any
      # binding is read.
      NOT_SCHEDULABLE = :deliver_at_not_steerable
      # THE TWO BOUNDS ON THE CLOCK — bounds on a datetime, never a ceiling
      # on work. The references AGREE on refuse-beyond-a-short-grace: hermes
      # refuses a one-shot more than 120 s past, openclaw more than 60 s;
      # hermes' number is taken as the wider, written for a model's
      # hand-computed stamp and forgiving of a client clock a minute slow.
      # Inside the grace the row is simply due and keeps the time it asked
      # for. The far bound is openclaw's ten years (hermes has none): a
      # datetime that must never reach the column or Solid Queue's
      # `scheduled_at`, the `MAX_RETRY_AFTER_SECONDS` reasoning on the
      # invocation side.
      PAST_GRACE = 2.minutes
      IN_PAST = :deliver_at_in_past
      FUTURE_BOUND = ConversationInput::FUTURE_BOUND
      TOO_FAR = :deliver_at_too_far

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
        @host = command.host
      end

      def call
        # The door's standing: a caller writes at `full`; the kernel's own
        # mail is exempt from the level, never from the workspace — the
        # loop's creator may hold `read` while the answerer's engine mails
        # its receipt. Read lock-free before the host lock: a narrowing
        # landing concurrently can admit one row from a principal now
        # `none` — parity with the workspace rule, no corruption.
        return Outcome.refused(:not_authorized) unless writable?

        result = nil
        # requires_new is load-bearing: under the receipt wrapper a bare
        # block joins its transaction and the Rollback is swallowed, committing a phantom row.
        @host.with_lock(requires_new: true) do
          AgentRuns::SourceWork.with_source(@command.run_public_id) do |source|
            result = if AgentRuns::SourceWork.stopped?(@command.run_public_id, source)
              Outcome.refused(:source_stopped)
            elsif @command.delegation
              @command.delegation.reload
              if @command.delegation.delegated_input_public_id
                Outcome.refused(:delegation_published)
              elsif AgentRuns::Delegations.owner_stopped?(@command.delegation)
                Outcome.refused(:delegation_canceled)
              else
                locked_accept
              end
            else
              locked_accept
            end
          end
          # Anything short of acceptance takes back every write — the input
          # row must never commit without the body its refusal orphaned.
          raise ActiveRecord::Rollback unless result.accepted?
        end
        result
      end

      private

        def writable?
          if @command.kernel?
            @host.workspace.writable_by?(@command.acting_user)
          else
            @host.writable_by?(@command.acting_user)
          end
        end

        def locked_accept
          refusal = @host.input_refusal
          # Archive refuses a principal's mail but admits the kernel's own
          # — a background task's answer lands as a subagent's notice does
          # (the row's `host_admits_the_input` reads the same set);
          # absence seals even for the kernel.
          return Outcome.refused(refusal) if refusal && !admitted_past_archive?(refusal)

          refusal = Admission.refusal(host: @host, command: @command) ||
            steering_mode_refusal || schedule_refusal || freshness_refusal || capacity_refusal || speaker_refusal
          return refusal if refusal

          # Steer-on-idle falls back to queue: nothing to redirect, but the words are still
          # worth delivering.
          binding = nil
          if @command.delivery_mode == "steer"
            binding = ApplicationRecord.uncached { @host.steer_binding }
          end

          addressee, refusal = resolve_addressee(binding)
          return refusal if refusal

          binding = bound_to(binding, addressee)
          if @command.expected_steering_run_public_id
            accept_guarded(binding, addressee)
          else
            accept(binding, addressee)
          end
        end

        # THE ADDRESSEE: the named profile through the one rule
        # (`TurnPrincipals.resolve`, shared with the estimate that previews
        # this door) — `@handle` or a public id within the account, the
        # system user never — refused by name (`principal_unknown`) or as
        # ineligible (`answerer_not_eligible`, the create door's word: a
        # Human, `read` on the row, a fenced profile all read the same).
        # The kernel's own mail skips the eligibility. Unnamed: the running
        # reply's answerer for a steer, else the host's default.
        def resolve_addressee(binding)
          resolved = TurnPrincipals.resolve(
            host: @host, author: @command.acting_user, address: @command.answering_user_public_id,
            default: default_addressee(binding), kernel: @command.kernel?
          )
          return [nil, resolved] unless resolved.accepted?

          [resolved.value.answerer, nil]
        end

        # An UNNAMED steer addresses the RUNNING answerer: rho's `say`
        # steers with no `--to`, and the conversation's default would
        # queue the correction past the agent actually running. Read
        # once from the binding, under the host lock.
        def default_addressee(binding)
          return binding.answering_user if @host.hosts_turns? && binding

          @host.answering_user
        end

        # The steer conjunct: a steer joins the reply in flight only when
        # it names the answerer running it; a named other addressee finds
        # no turn and QUEUES — nothing corrupts, so no refusal. A one-turn
        # host's `:self` is its own answerer by construction.
        def bound_to(binding, addressee)
          return binding unless @host.hosts_turns? && binding

          binding if binding.answering_user_id == addressee.id
        end

        def steering_mode_refusal
          if @command.expected_steering_run_public_id && @command.delivery_mode != "steer"
            Outcome.refused(:steering_guard_requires_steer)
          end
        end

        # The running candidate can differ from the displayed active variant during
        # regeneration. Pin that execution, and serialize acceptance with its terminal
        # transition so an already-delivered reply cannot receive another correction.
        def accept_guarded(binding, addressee)
          variant = binding&.conversation_turn_variants&.live&.find_by(status: ConversationTurnVariant::ACTIVE_STATUSES)
          agent_run = variant&.agent_run
          return Outcome.refused(:steering_target_changed) unless
            agent_run&.public_id == @command.expected_steering_run_public_id

          agent_run.with_lock do
            if agent_run.terminal? || agent_run.status == "canceling" || agent_run.delivered? || agent_run.stopped_at
              Outcome.refused(:steering_target_changed)
            else
              accept(binding, addressee)
            end
          end
        end

        def admitted_past_archive?(refusal)
          refusal == :conversation_archived && @command.kernel?
        end

        # THE CLOCK AT THE DOOR: a row's time is judged once, under the host
        # lock, against the database's clock — read only when a time was
        # named, so an untimed accept costs no statement. The steer conjunct
        # first (nothing to bind a future word to), then the two bounds. The
        # `now` read here is the one the kick below is measured against.
        def schedule_refusal
          at = @command.deliver_at
          return nil if at.nil?
          return Outcome.refused(NOT_SCHEDULABLE) if @command.delivery_mode == "steer"

          @now = DatabaseClock.now
          return Outcome.refused(IN_PAST) if at < @now - PAST_GRACE
          return Outcome.refused(TOO_FAR) if at > @now + FUTURE_BOUND

          nil
        end

        # Checked at accept under the host lock — the synchronous refusal
        # the sender can act on; from here the queue order is the contract.
        # A host without a timeline admits neither fence, so neither reads.
        def freshness_refusal
          expected_revision = @command.expected_context_revision
          if expected_revision && expected_revision != @host.context_revision
            return Outcome.refused(:stale_context)
          end

          expected_tail = @command.expected_tail_turn_public_id
          if expected_tail
            tail = ApplicationRecord.uncached do
              @host.conversation_turns.live.order(position: :desc).first
            end
            return Outcome.refused(:stale_timeline) if tail&.public_id != expected_tail
          end
          nil
        end

        # The caller-authored bound counts peer mail too — an agent's
        # `send` included — and an over-limit send refuses
        # SYNCHRONOUSLY: Claude Code's inbox-full semantics with no new
        # flow-control machinery. The kernel's own set is not counted
        # (`caller_authored`) but can meet the bound like any row: a
        # refused mail is retried, never dropped.
        def capacity_refusal
          held = ApplicationRecord.uncached do
            @host.conversation_inputs.caller_authored.count
          end
          return Outcome.refused(:input_queue_full) if held >= @host.input_queue_limit

          nil
        end

        # THE ADDRESSEE'S ENGINE (`Conversations::AnswerEngine`, the ONE
        # ladder): a reply row addressed away from the host's default answerer,
        # and every row a peer SENT (a `send`, the spawn brief — the initiator's
        # words), run on the addressee's own preset, else what answered for it
        # here, else what answered here, else the row's own words. The host's
        # own rows posted as itself and the kernel's mail keep the trio they
        # carry.
        def answer_engine(addressee)
          return nil if @command.kernel? || @command.kind != "direct_reply" || !@host.hosts_turns?
          return nil if addressee.id == @host.answering_user_id && !@command.sent?

          AnswerEngine.selection(@host, addressee: addressee)
        end

        def accept(binding, addressee)
          engine = answer_engine(addressee)
          input = @host.conversation_inputs.new(
            account: @host.account,
            queue_position: next_queue_position,
            kind: @command.kind,
            role: @command.role,
            state: binding ? "steering" : "pending",
            delivery_mode: @command.delivery_mode,
            context_mode: @command.context_mode || ConversationInput::DEFAULT_CONTEXT_MODE,
            context_options: @command.context_options || {},
            steering_target_turn: (binding if @host.hosts_turns?),
            speaker: speaker,
            authoring_user: @command.acting_user,
            answering_user: addressee,
            visible_in_context: @command.visible_in_context != false,
            expected_context_revision: @command.expected_context_revision,
            expected_tail_turn_public_id: @command.expected_tail_turn_public_id,
            expected_steering_run_public_id: @command.expected_steering_run_public_id,
            provider_id: engine ? engine.provider_id : @command.provider_id,
            model_ref: engine ? engine.model_ref : @command.model_ref,
            reasoning_effort: engine ? engine.reasoning_effort : @command.reasoning_effort,
            reasoning_enabled: engine ? engine.reasoning_enabled : @command.reasoning_enabled,
            request_options: @command.request_options || {},
            tool_names: @command.tool_names,
            approval_mode: @command.approval_mode,
            instructions: @command.instructions,
            origin: @command.origin,
            sender_conversation_public_id: @command.sender_conversation_public_id,
            sender_run_public_id: @command.run_public_id,
            sender_task_key: @command.task_key,
            callback_result: @command.callback_result,
            deliver_at: @command.deliver_at,
            steps: @command.steps,
          )
          return Outcome.invalid(input) unless input.save

          @command.delegation&.update!(delegated_input_public_id: input.public_id)

          message = compose_message
          return Outcome.refused(message.refusal) unless message.accepted?

          body = ContentBodies::Replace.call(
            owner: input, role: "input", entries: message.entries,
            uploads: message.uploads, readable_text: message.readable_text
          )
          return Outcome.refused(body.refusal) unless body.accepted?

          @host.note_activity
          narrate(input)
          # The queue-default wake, for every accepted row — the kernel's
          # receipt included: an idle recipient begins processing
          # immediately. Rails defers the enqueue to commit, so a
          # rolled-back acceptance kicks nothing. A scheduled row's is the
          # SAME kick at the time it is due: one enqueue per accept; a time
          # inside the grace is due and kicks now.
          @host.wake_drain(at: wake_at(input))
          Outcome.accepted(input)
        end

        def wake_at(input)
          at = input.deliver_at
          at if at && at > @now
        end

        # The message as the body stores it: `text` + `attachments` compose
        # the one parts entry, bound and pinned under the host lock; raw
        # `entries` bind what they placed; a plain text is today's bytes. A
        # steer with any picture refuses by name, before any row is pinned.
        def compose_message
          attachments = @command.attachments
          entries = @command.entries
          placed = attachments.nil? ? ContentBodies::AttachedMessage.placed_ids(entries) : Array(attachments)
          if placed.any? && @command.delivery_mode == "steer"
            return ContentBodies::AttachedMessage::Result.refused(NOT_STEERABLE)
          end

          if attachments.nil?
            ContentBodies::AttachedMessage.placed(
              account: @host.account, creating_user: @command.acting_user, entries: entries
            )
          else
            unless ContentBodies::AttachedMessage.text_shaped?(entries)
              return ContentBodies::AttachedMessage::Result.refused(ContentBodies::AttachedMessage::WITH_ENTRIES)
            end

            ContentBodies::AttachedMessage.compose(
              account: @host.account, creating_user: @command.acting_user,
              text: Array(entries).first&.fetch("text", nil), attachments: attachments
            )
          end
        end

        def next_queue_position
          (@host.conversation_inputs.maximum(:queue_position) || -1) + 1
        end

        # Narrated in the same transaction as the row, so the log and the
        # row state commit atomically; the broadcast rides after commit.
        def narrate(input)
          ConversationEvent::Append.call(
            host: @host,
            idempotency_key: input.public_id,
            items: [{
              type: "input_accepted",
              payload: {
                "input_public_id" => input.public_id,
                "queue_position" => input.queue_position,
                "state" => input.state,
                "delivery_mode" => input.delivery_mode,
                "kind" => input.kind,
                "role" => input.role,
                # Every row names its sourcing: a follower prints `mailed r3t1`
                # from the kernel's word here, never from a flag — and its
                # author, kind recorded, and the sender stamp when one rides the
                # row.
                "origin" => input.origin,
                "sender_conversation_public_id" => input.sender_conversation_public_id,
                "authored_by" => authored_by(input),
                # And its addressee: who this row wakes.
                "answering_user_public_id" => input.answering_user.public_id,
                # And when, on a scheduled row — the operator's evidence of
                # a self-timer beside `origin: agent`.
                "deliver_at" => input.deliver_at&.iso8601,
                "run_public_id" => @command.run_public_id,
                "task_key" => @command.task_key,
              }.compact,
            }]
          )
        end

        def authored_by(input)
          author = input.authoring_user
          { "kind" => author.kind, "handle" => author.handle, "display_name" => author.display_name }
        end

        def speaker_refusal
          return nil if @command.speaker_public_id.nil?

          @ingress_speaker = Speaker.find_by(public_id: @command.speaker_public_id, account_id: @host.account_id)
          return Outcome.refused(:not_authorized) unless @ingress_speaker&.ingress_controlled_by?(@command.acting_user)
          return nil if @command.role == "user"

          record = @host.conversation_inputs.new
          record.errors.add(:role, :invalid)
          Outcome.invalid(record)
        end

        def speaker
          return @ingress_speaker if @ingress_speaker

          Speakers::Resolve.member(
            account: @host.account, user: @command.acting_user
          )
        end
    end
  end
end
