module AgentLoops
  # KERNEL MAIL: a
  # detached background task's answer reaches the model after its original reply
  # through the one input door — a kernel-stamped user-role input
  # that always queues (never a steer: a running turn finishes first),
  # drains FIRST among the queued rows. The default wakes an idle conversation
  # as a new turn; passive mail lands as a message for later context without
  # invoking a model. Automatic mail uses the mailing loop's model trio,
  # its approval tightening while it still tightens, and only tools its
  # seed declared that the answering profile still declares. An empty
  # intersection stays empty. Level-triggered over the tips
  # no explicit reader consumed, each under a hosted receipt so a job retried
  # after the row committed replays instead of minting twice, and stamped
  # `mailed_at` by a guarded write in the accepting transaction. Runs in its
  # own job: the door takes the conversation lock, which the loop lock —
  # the quiescence site's — must never hold.
  #
  # ONE KERNEL-MAIL WRITER: a spawned
  # child's reply that finds no open await is mailed by the same code —
  # `Mail.child_reply` — authored exactly as task mail is: the requesting
  # loop's creator, addressed to that execution's answerer on its surface; the
  # child's identity rides the sender stamp and the envelope's
  # `conversation=`, and the row says `origin: child`. The kernel relays
  # its own receipt and impersonates nobody.
  class Mail
    ORIGIN = ConversationInput::TASK_RESULT_ORIGIN
    CHILD_ORIGIN = ConversationInput::CHILD_ORIGIN
    DELIVERABLE_STATUSES = %w[running paused needs_attention completed].freeze
    Sent = ConversationCommandReceipt::Idempotent::Success

    class << self
      def call(agent_loop) = new(agent_loop).call

      # Whether the next pass owes a job: settled, unread, unmailed tips
      # on a loop whose reply is final.
      def pending?(agent_loop)
        DELIVERABLE_STATUSES.include?(agent_loop.status) &&
          !agent_loop.tombstoned? && !agent_loop.stopped? && !agent_loop.standalone? && agent_loop.delivered? &&
          !SourceWork.stopped_source?(agent_loop) &&
          WakeContinuation.undelivered(agent_loop).any?
      end

      # Materialize the source window before graph/host predicates. Consumed
      # tips and intermediate nodes remain here, so recovery carries a cursor.
      def recovery_candidates(after_id:, limit:)
        AgentLoopNode.where(detached: true, mailed_at: nil, status: AgentLoopNode::TERMINAL_STATUSES)
          .where(id: (after_id + 1)..).order(:id).limit(limit)
      end

      # The mail path of the child-reply relay: the loop that sent this
      # request owns its reply, including a later send by another Agent.
      # The turn keeps that request's task key after its input is consumed.
      # Answers `:mailed`, or the door's refusal; the
      # relay marker is stamped INSIDE the receipt's transaction (a crash
      # between the accept and the stamp would otherwise re-deliver once
      # the receipt expires) and again, guarded, on a replay.
      def child_reply(agent_loop:, child:, turn:)
        new(agent_loop).relay(child, turn)
      end

      # The clock's execution is a normal child, but has no old spawning
      # task to retain. Its actual answering loop owns the callback source.
      def scheduled_reply(child:, turn:)
        job = child.scheduled_job
        parent = child.parent_conversation
        return :not_found unless job && parent && !parent.tombstoned? && !parent.workspace.tombstoned?

        variant = Delegations.answering_variant(turn)
        source = variant&.agent_loop
        return :source_stopped if source && SourceWork.stopped?(source.public_id, source)

        selected = source ? surface(source) : {
          provider_id: variant&.provider_id, model_ref: variant&.model_ref,
          reasoning_effort: variant&.reasoning_effort, tool_names: [], approval_mode: nil,
        }
        new(source, conversation: parent, creating_user: job.creating_user,
          answering_user: turn.answering_user, surface: selected).relay_scheduled(child, turn, variant)
      end

      # The child's reply as its timeline renders it — the converger's
      # adopted deliverable — else the fact that there is none: what the
      # child's turn became.
      def reply_text(turn, variant: turn.active_variant)
        text = variant&.content_bodies&.find_by(role: "content")&.effective_text
        text.presence || no_reply_text(turn, variant: variant)
      end

      # A reply a provider declined says who declined it — the refusal that
      # stood, the answerer's fallback's when one asked again — and what the
      # reader can do next: a bare "no text" invites the same brief again.
      def no_reply_text(turn, variant: turn.active_variant)
        invocation = Delegations.answering_sample(variant)&.model_invocation
        return RefusalSentence.for_reply(invocation) if invocation&.declined?

        "(the reply ended #{turn.status} with no text)"
      end

      # The woken turn's request surface, read off the loop that mailed:
      # the current main-line round carries its selection, the loop row its approval
      # word, the seed round its narrowed tools.
      def surface(agent_loop)
        selection = CurrentModel.for(agent_loop)
        {
          provider_id: selection.provider_id, model_ref: selection.model_ref,
          reasoning_effort: selection.reasoning_effort,
          approval_mode: inherited_approval_mode(agent_loop),
          tool_names: inherited_tool_names(agent_loop),
        }
      end

      private

        # The loop's frozen word while it still tightens the profile's
        # current one (rank ≥, the row's own rule); else nil, the profile's.
        def inherited_approval_mode(agent_loop)
          rank = ConversationInput::APPROVAL_RANK
          declared = rank[agent_loop.declaring_profile&.approval_mode]
          frozen = rank[agent_loop.approval_mode]
          return agent_loop.approval_mode if declared.nil? && agent_loop.declaring_profile&.tool_definitions.blank?

          agent_loop.approval_mode if declared && frozen && frozen >= declared
        end

        # Profile changes may remove tools or rename a kernel alias; neither
        # restores tools the source turn lacked. Naming the full intersection
        # also keeps a queued receipt from acquiring later additions.
        def inherited_tool_names(agent_loop)
          seed = agent_loop.agent_loop_nodes.find_by(node_key: Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
          Nexus::ToolDeclarations.intersection_names(agent_loop.declaring_profile&.tool_definitions,
            inherited: seed&.tool_definitions)
        end
    end

    def initialize(agent_loop, conversation: nil, creating_user: nil, answering_user: nil, surface: nil)
      @agent_loop = agent_loop
      @conversation = conversation
      @creating_user = creating_user
      @answering_user = answering_user
      @surface = surface
    end

    # One outcome per tip, in settlement order: `:mailed`, or the door's
    # refusal — `input_queue_full` when the caller-authored bound is met
    # (the tip stays on the trace, the next job mails it).
    def call
      return [] unless self.class.pending?(@agent_loop)

      tips = WakeContinuation.undelivered(@agent_loop)
      boundary = ExpansionOwnership.owners(@agent_loop, tips.map(&:node_key))
      tips.map { |tip| mail(tip, boundary: boundary.key?(tip.node_key)) }
    end

    # The child's reply as this loop's mail (see `Mail.child_reply`).
    def relay(child, turn)
      variant = turn.active_variant
      text = TaskResultEnvelope.child_reply(
        call_key: turn.sender_task_key, status: turn.status,
        conversation_public_id: child.public_id, body: self.class.reply_text(turn, variant: variant)
      )
      key = "spawn:#{child.public_id}:#{turn.public_id}"
      request = @agent_loop.agent_loop_nodes.find_by!(node_key: turn.sender_task_key)
      wake = KernelTool.wake(request, request.tool_input)
      result = receipt(
        key: key, envelope: { "spawn" => child.public_id, "turn" => turn.public_id, "text" => text },
        command: command(text, origin: CHILD_ORIGIN, sender: child, task_key: turn.sender_task_key, wake: wake,
          callback_result: CallbackResult.for(child: child, turn: turn, variant: variant))
      ) { turn.stamp_relayed }

      case result.outcome
      when :refused then refused(key, result.refusal)
      else
        turn.stamp_relayed
        :mailed
      end
    end

    def relay_scheduled(child, turn, variant)
      key = "scheduled:#{child.public_id}:#{turn.public_id}"
      # The original request owns the brief even when a fallback supplies the
      # answer. The job's editable intent describes future occurrences only.
      prompt = Delegations.original_variant(turn)&.content_bodies&.find_by(role: "prompt")&.effective_text
      text = TaskResultEnvelope.child_reply(call_key: child.scheduled_job_public_id,
        status: variant&.status || turn.status, conversation_public_id: child.public_id,
        body: self.class.reply_text(turn, variant: variant), prompt: prompt, scheduled_for: child.scheduled_for)
      result = receipt(key: key, envelope: { "scheduled_job" => child.scheduled_job_public_id,
        "conversation" => child.public_id, "turn" => turn.public_id, "text" => text },
        command: command(text, origin: CHILD_ORIGIN, sender: child,
          task_key: child.scheduled_job_public_id, wake: "auto",
          callback_result: CallbackResult.for(child: child, turn: turn, variant: variant, scheduled: true))) { turn.stamp_relayed }
      if result.outcome == :refused
        refused(key, result.refusal)
      else
        turn.stamp_relayed
        :mailed
      end
    end

    private

      def conversation = @conversation || @agent_loop.conversation
      def creating_user = @creating_user || @agent_loop.creating_user
      def answering_user = @answering_user || @agent_loop.answering_user

      def mail(tip, boundary: false)
        text = TaskResultEnvelope.for(tip, boundary: boundary)
        result = receipt(
          key: receipt_key(tip), envelope: { "mail" => tip.node_key, "text" => text },
          command: command(text, origin: ORIGIN, sender: conversation,
            task_key: TaskResultEnvelope.call_key(tip, boundary: boundary), wake: tip.wake)
        ) { stamp(tip) }

        case result.outcome
        when :refused then refused(tip.node_key, result.refusal)
        else stamp(tip)
        end
      end

      # The hosted receipt around the door (`request_digest` over the
      # envelope, as every receipt here is spelled); the block runs after
      # the accept, inside the receipt's own transaction.
      def receipt(key:, envelope:, command:)
        ConversationCommandReceipt::Idempotent.call(
          account: conversation.account, workspace: conversation.workspace,
          acting_user: creating_user, operation: :input_create,
          idempotency_key: key, host: conversation,
          request_digest: ConversationCommandReceipt.digest_for(operation: :input_create, envelope: envelope)
        ) do
          accepted = Conversations::Inputs::Create.call(command)
          next accepted unless accepted.accepted?

          yield if block_given?
          Sent.new(status: 202, body: { "input" => { "public_id" => accepted.value.public_id } },
            host: conversation)
        end
      end

      # Addressed to the mailing loop's own answerer: a task A started
      # answers to A's turn, never to the conversation's default and
      # never to everyone.
      def command(text, origin:, sender:, task_key:, wake:, callback_result: nil)
        passive = wake == "passive"
        Conversations::Inputs::Create::Command.kernel(
          host: conversation, acting_user: creating_user, kind: passive ? "message" : "direct_reply",
          entries: [{ "text" => text }], origin: origin,
          sender_conversation_public_id: sender.public_id,
          agent_loop_public_id: @agent_loop&.public_id,
          task_key: task_key,
          callback_result: callback_result,
          answering_user_public_id: answering_user.public_id,
          **(passive ? {} : surface)
        )
      end

      def surface = @surface ||= self.class.surface(@agent_loop)

      # Namespaced by the loop: every loop's keys start at `r1`, and the
      # receipt is scoped to the conversation, which hosts many loops.
      def receipt_key(tip) = "mail:#{@agent_loop.public_id}:#{tip.node_key}"

      # Guarded, not locked: `mailed_at` is not a status and two jobs racing
      # here both hold the same receipt.
      def stamp(tip)
        now = Time.current
        AgentLoopNode.where(id: tip.id, mailed_at: nil).update_all(mailed_at: now, updated_at: now)
        :mailed
      end

      def refused(key, refusal)
        Rails.logger.info(
          "event=agent_loop_mail_refused loop=#{@agent_loop&.public_id} " \
          "tip=#{key} reason=#{refusal.outcome}"
        )
        refusal.outcome
      end
  end
end
