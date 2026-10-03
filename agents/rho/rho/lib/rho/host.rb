module Rho
  # THE HOST a follower follows and a verb addresses: a
  # standalone agent loop, or a conversation rho opened. Both host the same
  # waiting room and the same feed at their own address, and the host —
  # never a branch on its kind — picks the SDK context, the input kind its
  # door admits, the stop verb, and when a re-adoption finds it finished.
  module Host
    # A standalone loop: `message` is the only kind its door admits, it
    # stops through its own lifecycle verb, and it is finished when its
    # own row says so (the loop-row read `LiveJourney` and `attach` share).
    AgentLoop = Data.define(:public_id) do
      def type = "agent_loop"

      def context(workspace) = workspace.agent_loops.agent_loop(public_id)

      # A loop is its own backing loop, and its follow ends with its one turn.
      def own_loop = public_id

      def outlives_turn? = false

      # A standalone loop is no conversation: a grant made on it records none.
      def conversation_public_id = nil

      # A loop host's `message` has no model, no subset, no approval
      # tightening and no addressee (a loop has one answerer; the daemon
      # refuses a `to` before it reaches here): the kwargs are the one
      # signature both hosts answer. `attachments` are the staged
      # upload ids the daemon minted for the person's pictures; both doors
      # take them beside the words.
      # A time is not a loop's field either (its one turn is in flight;
      # the daemon refuses before the call): the kwargs are answered and
      # dropped here.
      def input_fields(text, mode:, model: nil, tool_names: nil, approval_mode: nil, to: nil, attachments: nil,
                       deliver_at: nil, deliver_in: nil)
        { kind: "message", text: text, delivery_mode: mode, attachments: attachments }.compact
      end

      def stop(context, force:) = context.stop(force: force).status

      def settled?(context) = CybrosAgent::Api::LOOP_TERMINAL_STATUSES.include?(context.fetch.status)

      # A loop names the round: nothing on a loop says which of its
      # queued rounds a person meant.
      def compact_refusal(task_key) = ("task_key is required on a loop: name the round to compact" if task_key.empty?)

      def compact(context, task_key:)
        answer = context.tasks_context(task_key).compact
        { host_type: type, public_id: public_id, task_key: answer.task.key,
          summary_task_key: answer.summary_task_key }
      end
    end

    # A conversation: what a person says is a `direct_reply` whose text is
    # their words — one row, one materialization — on the model the
    # conversation last used, with the tool subset its tier names beside
    # it (nil runs the whole declaration); `approval_mode` is the turn's
    # tightening of the profile's word, on THIS input only;
    # stopping it is the cancellation verb, and a conversation stands
    # until somebody deletes it.
    Conversation = Data.define(:public_id) do
      def type = "conversation"

      def context(workspace) = workspace.conversations.conversation(public_id)

      # The backing loop is the current TURN's, learned from the feed; the
      # conversation stands past every turn terminal, so its follow does too.
      def own_loop = nil

      def outlives_turn? = true

      # The host IS the conversation: what a grant made on one of its
      # turns' loops records (`rho rules`).
      def conversation_public_id = public_id

      # `to` is WHO ANSWERS the turn, a member's public id the
      # daemon resolved; the SDK spells it onto the wire's
      # `answering_user_public_id`. Nil is the kernel's default.
      # `deliver_at`/`deliver_in` are the
      # kernel's two wire fields, passed through as typed: the kernel is
      # the one parser, and the door judges the instant.
      def input_fields(text, mode:, model: nil, tool_names: nil, approval_mode: nil, to: nil, attachments: nil,
                       deliver_at: nil, deliver_in: nil)
        { kind: "direct_reply", text: text, delivery_mode: mode, model: model, tool_names: tool_names,
          approval_mode: approval_mode, to: to, attachments: attachments,
          deliver_at: deliver_at, deliver_in: deliver_in }.compact
      end

      def stop(context, force:)
        context.cancel
        "canceling"
      end

      def settled?(_context) = false

      # The kernel picks the round on a conversation: the running reply's
      # next queued one, or the whole history when idle.
      def compact_refusal(task_key) = ("a conversation picks its own round: no task_key" unless task_key.empty?)

      def compact(context, task_key:)
        answer = context.compact
        { host_type: type, public_id: public_id, turn: answer.turn_public_id,
          turn_kind: answer.kind, task_key: answer.task_key, summary_task_key: answer.summary_task_key }.compact
      end
    end

    # Keyed by the wire's own spelling of a host (`resource.type` on the
    # feed, Rails' singular model name), which is what a store row keeps.
    TYPES = { "agent_loop" => AgentLoop, "conversation" => Conversation }.freeze

    def self.from(type, public_id) = TYPES.fetch(type).new(public_id: public_id)

    # THE ONE RESOLUTION RULE for a verb given a LOOP id: a row rho
    # placed carries the host, whether the id is the host's own or the
    # backing loop of a conversation it follows; else the loop's own turn
    # block says whose it is — a `conversation_public_id` means the loop
    # is loop-backed and its feed is its conversation's (the loop feed
    # would refuse `conversation_hosted`), none means it is its own host.
    def self.resolve(public_id, rows:, fetch_loop:)
      row = rows.find { |candidate| candidate.host_public_id == public_id || candidate.loop == public_id }
      return row.host if row

      conversation = fetch_loop.call(public_id).turn&.conversation_public_id
      conversation ? Conversation.new(public_id: conversation) : AgentLoop.new(public_id: public_id)
    end
  end
end
