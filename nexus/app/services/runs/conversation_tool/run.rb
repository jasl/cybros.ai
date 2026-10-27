module Runs
  module ConversationTool
    # Ordinary messages preserve sender attribution but create recipient-owned
    # work after consumption. Status and cancel retain their data-access gates.
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
        return :not_mutable unless run.graph_mutable?
        return settle(format(NO_CONVERSATION, verb), is_error: true) if run.standalone?

        return post_message if verb == "send"
        return list_links if verb == "links"

        settle(answer)
      rescue Refused => error
        settle(error.message, is_error: true)
      end

      private

        def run = @node.run
        def conversation = run.conversation
        def verb = @node.tool_name
        def input = @node.tool_input
        # The profile whose engine made the call: the row's author. The
        # loop's `creating_user` is the SPEAKER and may be a Human.
        def sender = run.answering_user

        # Message publication and link discovery settle their own structured results.
        def answer
          case verb
          when "status" then status_line
          when "cancel" then cancel_tree
          else raise ArgumentError, "no conversation verb #{verb.inspect}"
          end
        end

        # ── the address ──────────────────────────────────────────────

        def target(admit_ancestors: false)
          resolution = Conversations::ConversationAddress.resolve(
            sender_conversation: conversation, sender: sender, address: input["to"],
            admit_ancestors: admit_ancestors, reach: Conversations::Reach.of(@node)
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
          return false unless conversation.subagent? && candidate.id == conversation.parent_conversation_id

          conversation.spawn_node&.spawn_await&.started? == true
        end

        # `agent` by @handle or public id through the one resolver, nil
        # when unnamed (the door's default: the running answerer for a
        # steer, else the host's). Named but nobody's is refused here with
        # the agents it could have named; ineligible is the door's word.
        def agent_for(run)
          address = input["agent"]
          return nil if address.blank?

          User.members.addressed_by(run.workspace.account_id, address).first ||
            raise(Refused, self.class.principal_unknown(run.workspace, address))
        end

        def list_links
          state = input.fetch("state", "active")
          raise Refused, "invalid_state" unless %w[active closed all].include?(state)
          limit = Integer(input.fetch("limit", 50), exception: false)
          raise Refused, "invalid_limit" unless limit && (1..100).cover?(limit)
          after = input["after"]
          raise Refused, "invalid_after" if after && !Input.uuid_shaped?(after)

          scope = ConversationLink.where(first_conversation_id: conversation.id, first_agent_id: sender.id)
            .or(ConversationLink.where(second_conversation_id: conversation.id, second_agent_id: sender.id))
          scope = scope.active if state == "active"
          scope = scope.where.not(closed_at: nil) if state == "closed"
          scope = scope.where("conversation_links.public_id < ?", after) if after
          rows = scope.includes(:workspace, :first_conversation, :second_conversation, :first_agent, :second_agent)
            .order(public_id: :desc).limit(limit + 1).to_a
          page = rows.first(limit)
          result = { "links" => page.map { |link| ::Conversations::LinkProjection.call(link, conversation: conversation).as_json },
            "next_after" => (page.last.public_id if rows.length > limit) }
          KernelTool.settle(@node, JSON.generate(result), title: "links", structured_content: result)
        end

        # ── send ─────────────────────────────────────────────────────

        def post_message
          message = input["message"].to_s
          raise Refused, EMPTY_MESSAGE if message.strip.empty?
          raise Refused, "unsupported_send_field" if (input.keys & %w[steer model wake]).any?
          raise Refused, "invalid_delivery_mode" unless Input::DELIVERY_MODES.include?(input.fetch("delivery_mode", "queue"))
          if input["link_public_id"]
            raise Refused, "invalid_link_target" if input["to"] || input["agent"]
            @link = ConversationLink.find_by(public_id: input["link_public_id"], workspace_id: run.workspace_id)
            peer = @link&.peer(conversation: conversation, agent: sender)
            raise Refused, "not_found" unless peer
            raise Refused, "conversation_link_closed" if @link.closed?
            addressee, agent = peer
          else
            addressee, agent = target, agent_for(run)
          end
          deliver(addressee, agent, message, input.fetch("delivery_mode", "queue"), deliver_at_reading)
          :applied
        end

        # The hosted receipt around the door, keyed on the call: a job
        # retried past the row's commit reads its own receipt and posts
        # nothing twice (the `ResultDelivery` shape). Keep the accepted delivery
        # state and deadline in that receipt: replay must not promise a new
        # reply after a steer was consumed or move a relative deadline.
        def deliver(addressee, agent, message, delivery_mode, delivery_time)
          envelope = { "send" => addressee.public_id, "agent" => agent&.public_id, "text" => message, "delivery_mode" => delivery_mode, "expected_steering_run_public_id" => input["expected_steering_run_public_id"], "on_target_end" => input["on_target_end"], "link_public_id" => @link&.public_id }
          envelope["deliver_at"] = delivery_time.time.utc.floor.iso8601 if delivery_time.time
          envelope["deliver_in_seconds"] = delivery_time.delay_seconds unless delivery_time.delay_seconds.nil?
          deliver_at = nil
          result = ConversationCommandReceipt::Idempotent.call(
            account: run.account, workspace: run.workspace, acting_user: sender,
            operation: :input_create, idempotency_key: "send:#{run.public_id}:#{@node.node_key}",
            host: addressee,
            request_digest: ConversationCommandReceipt.digest_for(operation: :input_create, envelope: envelope)
          ) do
            deliver_at = delivery_time.resolve(now: Time.current)&.utc&.floor
            accepted = Conversations::Inputs::Create.call(command(addressee, agent, message, delivery_mode, deliver_at)) do |row|
              receipt = { "input_public_id" => row.public_id, "conversation_public_id" => addressee.public_id,
                "answering_user_public_id" => row.answering_user.public_id, "link_public_id" => @link&.public_id,
                "delivery_mode" => row.delivery_mode, "expected_steering_run_public_id" => row.expected_steering_run_public_id,
                "requested_delivery_mode" => row.requested_delivery_mode, "fallback_reason" => row.fallback_reason,
                "deliver_at" => row.deliver_at&.utc&.iso8601, "state" => row.state }
              outcome = KernelTool.settle(@node, JSON.generate(receipt), title: "send", structured_content: receipt, locked: true)
              raise Refused, outcome.to_s unless %i[applied idle].include?(outcome)
            end
            next accepted unless accepted.accepted?

            Sent.new(status: 202,
              body: { "input" => { "public_id" => accepted.value.public_id, "state" => accepted.value.state,
                                    "deliver_at" => accepted.value.deliver_at&.utc&.iso8601 } },
              host: addressee)
          end

          case result.outcome
          when :refused
            return if result.refusal.outcome == :communication_published
            raise Refused, door_refusal(result.refusal.outcome, addressee, agent, deliver_at)
          when :mismatched then raise Refused, door_refusal(:idempotency_envelope_mismatch, addressee, agent)
          when :executed then result.response.body.fetch("input")
          when :replayed then result.receipt.response_body.fetch("input")
          else raise ArgumentError, "unknown send receipt outcome #{result.outcome.inspect}"
          end
        end

        def command(addressee, agent, message, delivery_mode, deliver_at)
          Conversations::Inputs::Create::Command.sent(
            host: addressee, acting_user: sender, kind: "direct_reply",
            entries: [{ "text" => message }], delivery_mode: delivery_mode,
            expected_steering_run_public_id: input["expected_steering_run_public_id"],
            on_target_end: input["on_target_end"],
            sender_conversation_public_id: conversation.public_id,
            run_public_id: run.public_id, task_key: @node.node_key,
            communication_kind: "message", conversation_link: @link,
            answering_user_public_id: agent&.public_id, deliver_at: deliver_at,
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
            [addressee.turns.active.exists?,
             addressee.inputs.where(state: %w[pending steering]).count,
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
          conversation.inputs.pending.merge(Input.due(DatabaseClock.now))
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
