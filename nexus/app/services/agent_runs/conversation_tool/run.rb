module AgentRuns
  module ConversationTool
    # The three verbs on a conversation another agent answers,
    # ONE executor keyed by the call's wire word:
    #
    # `send` — the SENDER's own row on the addressee through the one input
    # door (`Command.sent`: author = the profile whose engine made the
    # call, its kind on the row as `origin: agent`, this conversation's
    # stamp — the kernel impersonates nobody). `to` is WHERE and `agent`
    # is WHO: an optional principal inside that conversation, by
    # @handle or public id, riding the door's one member
    # `answering_user_public_id` — absent, the conversation's own
    # answerer. A reply head on the ADDRESSEE's engine (`Conversations::AnswerEngine`'s
    # one order, run at the door): the
    # addressee's own preset, else its last reply turn's trio in the target
    # conversation, else the conversation's last reply turn's, else THE
    # INITIATOR'S model the row carries (`KernelTool.initiator_model`: the
    # call's `model`, else the calling round's configured model). Queued by
    # default; a STEER when the agent chose it and a reply is running there
    # (the door's steer-on-idle falls back to queue). Standing is the
    # sender's `full` on the addressee as the door judges it. A child whose
    # parent is blocking on it (`wait: true`, the await parked) is told to
    # answer instead (`parent_waiting`) — before the ancestor refusal,
    # so the teaching sentence wins. Idempotent under a retried job by a
    # hosted receipt keyed on the call. The settle promises a reply only
    # for the sender's own child, whose owed turns the relay carries back.
    #
    # `status` — three facts the model can act on (every extra field is a
    # model-facing name to measure): running or idle, the queue depth, who
    # answers. And a fourth only when it holds: how many messages from that
    # conversation wait in the CALLER's own queue — a reply relayed while
    # the caller's turn runs sits there, not on the addressee, and is read
    # when the caller ends its turn. The queue is the caller's
    # conversation's, so a branch of its loop reads the same bytes. A read:
    # an ancestor is admitted.
    #
    # `cancel` stops the addressee's executions and their dependent work,
    # including background work, after the sender's `full` check. Child
    # conversations remain reusable for independently requested work.
    #
    # Every refusal is an error envelope the round reads, named first.
    class Run
      class Refused < StandardError; end

      Sent = ConversationCommandReceipt::Idempotent::Success

      NO_CONVERSATION = "%s needs a conversation: this loop has none.".freeze
      EMPTY_MESSAGE = "message is empty. Say what the conversation should read.".freeze
      UNKNOWN = "unknown_conversation: to: %s names no conversation you can read here. Use the label you gave " \
        "it when you spawned it, or its public id.".freeze
      SIDE = "side_conversation: %s is a side conversation; it takes no messages.".freeze
      ANCESTOR = "ancestor_conversation: %s is above you in your own tree; a spawned conversation may not " \
        "send to or cancel the conversation it answers to.".freeze
      PARENT_WAITING = "parent_waiting: your parent is waiting for your reply; end your turn with the answer " \
        "instead of sending.".freeze
      NOT_AUTHORIZED = "not_authorized: you may read %s but not write in it.".freeze
      NOT_ELIGIBLE = "agent: %s cannot answer in %s: it is not an agent profile with write standing there.".freeze
      DOOR_REFUSED = "%s: the message to %s was refused.".freeze
      NOTHING_TO_CANCEL = "%s has no execution to stop or pending result to suppress.".freeze
      # The fourth fact's two spellings, chosen by the count; "end your turn"
      # is the task receipt's own phrase.
      QUEUED_FOR_YOU = "%d message from it waits for you, delivered when you end your turn.".freeze
      QUEUED_FOR_YOU_MANY = "%d messages from it wait for you, delivered when you end your turn.".freeze
      # THE CLOCK ON `send`: the parser's three refusals in one sentence,
      # and the door's three words — one arm each — as the model can act
      # on them.
      TIME_REFUSED = "deliver_at must be an ISO 8601 time with an offset (2026-09-16T09:00:00Z); " \
        "deliver_in a delay like 20m, 2h, 1d or 90s; not both".freeze
      NOT_SCHEDULABLE = "deliver_at_not_steerable: a timed message to %s cannot steer; drop steer or the time.".freeze
      IN_PAST = "deliver_at_in_past: %s is more than two minutes past for %s; name a later time, " \
        "or deliver_in for a delay from now.".freeze
      TOO_FAR = "deliver_at_too_far: %s is more than ten years ahead for %s.".freeze

      def self.call(node:) = new(node: node).call

      def self.canceled_text(target)
        "Canceled #{target.public_id}: its executions, background work, and dependent work are stopped. " \
          "Pending results owned by those executions are suppressed."
      end

      # THE DOOR WORD `principal_unknown` for an `agent` that is
      # nobody's — `spawn`'s and `send`'s alike — answered with the
      # agents it could have named (the `tools` precedent).
      def self.principal_unknown(workspace, address)
        agents = User.members.where(account_id: workspace.account_id, kind: :agent).includes(:steward, :derived_from)
          .order_by_display_name.select { |user| workspace.data_writable_by?(user) }
        "agent: #{address.to_s.inspect} names no member of this account. The agents are: " \
          "#{agents.map { |user| "@#{user.handle}" }.join(", ")}"
      end

      def initialize(node:)
        @node = node
      end

      def call
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_run.graph_mutable?
        return settle(format(NO_CONVERSATION, verb), is_error: true) if agent_run.standalone?

        settle(answer)
      rescue Refused => error
        settle(error.message, is_error: true)
      end

      private

        def agent_run = @node.agent_run
        def conversation = agent_run.conversation
        def verb = @node.tool_name
        def input = @node.tool_input
        # The profile whose engine made the call: the row's author. The
        # loop's `creating_user` is the SPEAKER and may be a Human.
        def sender = agent_run.answering_user

        # The registry routes exactly the three verbs here; a fourth would
        # be a registry entry with no arm, which is a bug, not a refusal.
        def answer
          case verb
          when "send" then post_message
          when "status" then status_line
          when "cancel" then cancel_tree
          else raise ArgumentError, "no conversation verb #{verb.inspect}"
          end
        end

        # ── the address ──────────────────────────────────────────────

        def target(admit_ancestors: false)
          resolution = Conversations::ConversationAddress.resolve(
            sender_conversation: conversation, sender: sender, address: input["to"],
            admit_ancestors: admit_ancestors
          )
          return resolution.conversation if resolution.refusal.nil?
          raise Refused, PARENT_WAITING if
            resolution.refusal == :ancestor_conversation && parent_waiting?(resolution.conversation)

          raise Refused, refusal_text(resolution)
        end

        def refusal_text(resolution)
          case resolution.refusal
          when :unknown_conversation then format(UNKNOWN, input["to"].to_s.inspect)
          when :side_conversation then format(SIDE, resolution.conversation.public_id)
          when :ancestor_conversation then format(ANCESTOR, resolution.conversation.public_id)
          else raise ArgumentError, "no address refusal #{resolution.refusal.inspect}"
          end
        end

        # The parent is blocking on THIS child: the spawn call's kernel-held
        # await is parked (gap 18's deadlock — a steer would wait for a
        # boundary that waits for the child). The reply is the answer.
        def parent_waiting?(candidate)
          return false unless candidate.id == conversation.parent_conversation_id

          conversation.spawn_node&.spawn_await&.started? == true
        end

        # `agent` by @handle or public id through the one resolver, nil
        # when unnamed (the door's default: the running answerer for a
        # steer, else the host's). Named but nobody's is refused here with
        # the agents it could have named; ineligible is the door's word.
        def agent_for(agent_run)
          address = input["agent"]
          return nil if address.blank?

          User.members.addressed_by(agent_run.workspace.account_id, address).first ||
            raise(Refused, self.class.principal_unknown(agent_run.workspace, address))
        end

        # ── send ─────────────────────────────────────────────────────

        def post_message
          message = String.try_convert(input["message"]).to_s
          raise Refused, EMPTY_MESSAGE if message.strip.empty?
          raise Refused, KernelTool::INVALID_WAKE unless KernelTool.valid_wake?(input)

          refusal = KernelTool.model_refusal(agent_run, input)
          raise Refused, refusal if refusal

          addressee = target
          agent = agent_for(agent_run)
          accepted = deliver(addressee, agent, message, input["steer"] == true, deliver_at_reading)
          state = accepted.fetch("state")
          sent = "Sent to #{addressee.public_id}#{agent ? ", for @#{agent.handle}" : ""}" \
            " (#{settle_state(state, accepted.fetch("deliver_at"))})"
          return "#{sent}." unless addressee.parent_conversation_id == conversation.id &&
            (addressee.spawn_node.present? || addressee.scheduled_execution?)
          if state == "steering"
            return "#{sent}; this joins the existing reply, which returns to the request that opened it."
          end

          if KernelTool.wake(@node, input) == "passive"
            return "#{sent}; its reply is recorded in your conversation history without starting another turn."
          end

          "#{sent}; its reply reaches you as <task_result task=\"#{@node.node_key}\" " \
            "conversation=\"#{addressee.public_id}\"> in a later message that is not from the person."
        end

        # The hosted receipt around the door, keyed on the call: a job
        # retried past the row's commit reads its own receipt and posts
        # nothing twice (the `ResultDelivery` shape). Keep the accepted delivery
        # state and deadline in that receipt: replay must not promise a new
        # reply after a steer was consumed or move a relative deadline.
        def deliver(addressee, agent, message, steer, delivery_time)
          envelope = { "send" => addressee.public_id, "agent" => agent&.public_id, "text" => message, "steer" => steer }
          envelope["deliver_at"] = delivery_time.time.utc.floor.iso8601 if delivery_time.time
          envelope["deliver_in_seconds"] = delivery_time.delay_seconds unless delivery_time.delay_seconds.nil?
          deliver_at = nil
          result = ConversationCommandReceipt::Idempotent.call(
            account: agent_run.account, workspace: agent_run.workspace, acting_user: sender,
            operation: :input_create, idempotency_key: "send:#{agent_run.public_id}:#{@node.node_key}",
            host: addressee,
            request_digest: ConversationCommandReceipt.digest_for(operation: :input_create, envelope: envelope)
          ) do
            deliver_at = delivery_time.resolve(now: Time.current)&.utc&.floor
            accepted = Conversations::Inputs::Create.call(command(addressee, agent, message, steer, deliver_at))
            next accepted unless accepted.accepted?

            Sent.new(status: 202,
              body: { "input" => { "public_id" => accepted.value.public_id, "state" => accepted.value.state,
                                    "deliver_at" => accepted.value.deliver_at&.utc&.iso8601 } },
              host: addressee)
          end

          case result.outcome
          when :refused then raise Refused, door_refusal(result.refusal.outcome, addressee, agent, deliver_at)
          when :mismatched then raise Refused, door_refusal(:idempotency_envelope_mismatch, addressee, agent)
          when :executed then result.response.body.fetch("input")
          when :replayed then result.receipt.response_body.fetch("input")
          else raise ArgumentError, "unknown send receipt outcome #{result.outcome.inspect}"
          end
        end

        def command(addressee, agent, message, steer, deliver_at)
          Conversations::Inputs::Create::Command.sent(
            host: addressee, acting_user: sender, kind: "direct_reply",
            entries: [{ "text" => message }], delivery_mode: steer ? "steer" : "queue",
            sender_conversation_public_id: conversation.public_id,
            run_public_id: agent_run.public_id, task_key: @node.node_key,
            answering_user_public_id: agent&.public_id, deliver_at: deliver_at,
            # The initiator's model rides the row; the door runs the one
            # ladder for every sent row and keeps these words as its last rung.
            **KernelTool.initiator_model(@node, input)
          )
        end

        # THE ONE PARSER: the SAME reader the member door calls —
        # `deliver_in` for a model with no clock, `deliver_at` for one that
        # was told a time. Keep the intent for the receipt; only its first
        # execution resolves this boundary's clock to whole seconds in UTC.
        # A refusal names the grammar; the door judges the instant.
        def deliver_at_reading
          reading = Conversations::Inputs::DeliverAt.parse(
            at: input["deliver_at"], in_: input["deliver_in"]
          )
          raise Refused, TIME_REFUSED if reading.refusal

          reading
        end

        # `scheduled for <ISO>` on a scheduled row; `steering`/`queued`
        # otherwise, preserved by the receipt after the input drains.
        def settle_state(state, deliver_at)
          return "steering" if state == "steering"
          return "scheduled for #{deliver_at}" if deliver_at

          "queued"
        end

        # The door's word, relayed by name: `not_authorized` is the level
        # (the sender reads but may not write), `answerer_not_eligible`
        # names the `agent` that may not answer there, the clock's three
        # each their own arm, the rest the door's own.
        def door_refusal(code, addressee, agent, deliver_at = nil)
          case code
          when :not_authorized then format(NOT_AUTHORIZED, addressee.public_id)
          when :answerer_not_eligible
            agent ? format(NOT_ELIGIBLE, input["agent"], addressee.public_id) : format(DOOR_REFUSED, code, addressee.public_id)
          when Conversations::Inputs::Create::NOT_SCHEDULABLE then format(NOT_SCHEDULABLE, addressee.public_id)
          when Conversations::Inputs::Create::IN_PAST then format(IN_PAST, deliver_at.iso8601, addressee.public_id)
          when Conversations::Inputs::Create::TOO_FAR then format(TOO_FAR, deliver_at.iso8601, addressee.public_id)
          else format(DOOR_REFUSED, code, addressee.public_id)
          end
        end

        # ── status ───────────────────────────────────────────────────

        def status_line
          addressee = target(admit_ancestors: true)
          running, waiting, queued = ApplicationRecord.uncached do
            [addressee.conversation_turns.active.exists?,
             addressee.conversation_inputs.where(state: %w[pending steering]).count,
             queued_for_caller(addressee)]
          end
          "conversation #{addressee.public_id} — #{running ? "running" : "idle"}; queue: #{waiting} waiting; " \
            "answered by @#{addressee.answering_user.handle}.#{queued_clause(queued)}"
        end

        # The addressee's rows on the caller's own conversation that its
        # next turn drains: pending and due (the drain's own filter) — a
        # steer lands at the next boundary anyway, a scheduled row is not in
        # the room yet. The sender stamp is on a child's relayed reply and a
        # peer's `send` alike, and on no person's row.
        def queued_for_caller(addressee)
          conversation.conversation_inputs.pending.merge(ConversationInput.due(DatabaseClock.now))
            .where(sender_conversation_public_id: addressee.public_id).count
        end

        def queued_clause(count)
          return "" if count.zero?

          " #{format(count == 1 ? QUEUED_FOR_YOU : QUEUED_FOR_YOU_MANY, count)}"
        end

        # ── cancel ───────────────────────────────────────────────────

        def cancel_tree
          addressee = target
          raise Refused, format(NOT_AUTHORIZED, addressee.public_id) unless addressee.writable_by?(sender)

          result = Conversations::Turns::Cancel.stop_tree(addressee)
          return format(NOTHING_TO_CANCEL, addressee.public_id) unless result.accepted?

          Conversations::Turns::ConvergeJob.perform_later
          self.class.canceled_text(addressee)
        end

        def settle(text, is_error: false)
          KernelTool.settle(@node, text, is_error: is_error, title: is_error ? "#{verb} refused" : verb)
        end
    end
  end
end
