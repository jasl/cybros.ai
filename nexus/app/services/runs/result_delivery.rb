module Runs
  # KERNEL MAIL: a
  # detached background task's answer reaches the model after its original reply
  # through the one input door — a kernel-stamped user-role input
  # that always queues (never a steer: a running turn finishes first),
  # drains FIRST among the queued rows. The default wakes an idle conversation
  # as a new turn; passive mail lands as a message for later context without
  # invoking a model. Automatic mail uses the mailing loop's model selection,
  # its approval tightening while it still tightens, and only tools its
  # seed declared that its captured declaration still permits. An empty
  # intersection stays empty. Level-triggered over the tips
  # no explicit reader consumed, each under a hosted receipt so a job retried
  # after the row committed replays instead of minting twice, and stamped
  # `result_delivered_at` by a guarded write in the accepting transaction. Runs in its
  # own job: the door takes the conversation lock, which the loop lock —
  # the quiescence site's — must never hold.
  #
  # Spawn and request completions use the same task-mail writer. Their stored
  # outcome retains the exact child identity, even after the child is deleted.
  # An await consumes that completion; only an unread completion becomes mail.
  class ResultDelivery
    ORIGIN = Input::TASK_RESULT_ORIGIN
    CHILD_ORIGIN = Input::CHILD_ORIGIN
    DELIVERABLE_STATUSES = %w[running paused needs_attention completed].freeze
    Sent = ConversationCommandReceipt::Idempotent::Success

    class << self
      def call(run) = new(run).call

      # Whether the next pass owes a job: settled, unread, unmailed tips
      # on a loop whose reply is final.
      def pending?(run)
        DELIVERABLE_STATUSES.include?(run.status) &&
          !run.tombstoned? && !run.stopped? && !run.standalone? && run.delivered? &&
          !SourceWork.stopped_source?(run) &&
          WakeContinuation.undelivered(run).any?
      end

      # Materialize the source window before graph/host predicates. Consumed
      # tips and intermediate nodes remain here, so recovery carries a cursor.
      def recovery_candidates(after_id:, limit:)
        Task.where(detached: true, result_delivered_at: nil, status: Task::TERMINAL_STATUSES)
          .where(id: (after_id + 1)..).order(:id).limit(limit)
      end

      # The clock's execution is a normal child, but has no old spawning
      # task to retain. Its actual answering loop owns the callback source.
      def scheduled_reply(child:, turn:)
        job = child.schedule
        parent = child.parent_conversation
        return :not_found unless job && parent && !parent.tombstoned? && !parent.workspace.tombstoned?

        variant = Delegations.answering_variant(turn)
        source = variant&.run
        return :source_stopped if source && SourceWork.stopped?(source.public_id, source)

        selected = source ? surface(source) : {
          provider_id: variant&.provider_id, model_ref: variant&.model_ref,
          reasoning_effort: variant&.reasoning_effort, reasoning_enabled: variant&.reasoning_enabled,
          tool_names: [], approval_mode: nil,
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
        return invocation.failure_detail if invocation&.finish_error?

        "(the reply ended #{turn.status} with no text)"
      end

      # The woken turn's request surface, read off the loop that mailed:
      # the current main-line round carries its selection, the loop row its approval
      # word, the seed round its narrowed tools.
      def surface(run)
        selection = CurrentModel.for(run)
        {
          provider_id: selection.provider_id, model_ref: selection.model_ref,
          reasoning_effort: selection.reasoning_effort,
          reasoning_enabled: selection.reasoning_enabled,
          approval_mode: inherited_approval_mode(run),
          tool_names: inherited_tool_names(run),
        }
      end

      private

        # The loop's frozen word while it still tightens the profile's
        # current one (rank ≥, the row's own rule); else nil, the profile's.
        def inherited_approval_mode(run)
          rank = Input::APPROVAL_RANK
          declared = rank[run.execution_configuration&.approval_mode]
          frozen = rank[run.approval_mode]
          return run.approval_mode if declared.nil? && !run.execution_configuration&.tool_approval_required?

          run.approval_mode if declared && frozen && frozen >= declared
        end

        # The source keeps its captured declaration, while Runner eligibility
        # and served tools stay live. The intersection cannot restore tools
        # the source lacked or import later additions.
        def inherited_tool_names(run)
          seed = run.tasks.find_by(node_key: Conversations::Inputs::ApplyNext::SEED_ROUND_KEY)
          public_id = seed&.operation_context&.dig("environment", "default_runner_executor_public_id")
          runner = Executor.find_by(account_id: run.account_id, public_id: public_id) if public_id
          tools = Tools::Assemble.for_agent(agent: run.execution_agent,
            declaration: run.agent_configuration, runner: runner)
          Nexus::ToolDeclarations.intersection_names(tools.definitions,
            inherited: seed&.tool_definitions)
        end
    end

    def initialize(run, conversation: nil, creating_user: nil, answering_user: nil, surface: nil)
      @run = run
      @conversation = conversation
      @creating_user = creating_user
      @answering_user = answering_user
      @surface = surface
    end

    # One outcome per tip, in settlement order: `:delivered`, or the door's
    # refusal — `input_queue_full` when the caller-authored bound is met
    # (the tip stays on the trace, the next job mails it).
    def call
      return [] unless self.class.pending?(@run)

      tips = WakeContinuation.undelivered(@run)
      boundary = ExpansionOwnership.owners(@run, tips.map(&:node_key))
      tips.map { |tip| mail(tip, boundary: boundary.key?(tip.node_key)) }
    end

    def relay_scheduled(child, turn, variant)
      key = "scheduled:#{child.public_id}:#{turn.public_id}"
      # The original request owns the brief even when a fallback supplies the
      # answer. The job's editable intent describes future occurrences only.
      prompt = Delegations.original_variant(turn)&.content_bodies&.find_by(role: "prompt")&.effective_text
      text = TaskResultEnvelope.child_reply(call_key: child.schedule_public_id,
        status: variant&.status || turn.status, conversation_public_id: child.public_id,
        body: self.class.reply_text(turn, variant: variant), prompt: prompt, scheduled_for: child.scheduled_for)
      result = receipt(key: key, envelope: { "schedule" => child.schedule_public_id,
        "conversation" => child.public_id, "turn" => turn.public_id, "text" => text },
        command: command(text, origin: CHILD_ORIGIN, sender_public_id: child.public_id,
          task_key: child.schedule_public_id, wake: "auto",
          callback_result: CallbackResult.for(child: child, turn: turn, variant: variant, scheduled: true))) { turn.stamp_relayed }
      if result.outcome == :refused
        refused(key, result.refusal)
      else
        turn.stamp_relayed
        :delivered
      end
    end

    private

      def conversation = @conversation || @run.conversation
      def creating_user = @creating_user || @run.creating_user
      def answering_user = @answering_user || @run.answering_user

      def mail(tip, boundary: false)
        text = TaskResultEnvelope.for(tip, boundary: boundary)
        identity = TaskResultProjection.call(tip)["structured_content"] if tip.delegation?
        callback = if identity && identity["variant_public_id"]
          identity.merge("requester_speaker_public_id" => CallbackResult.for_loop(@run))
        end
        result = receipt(
          key: receipt_key(tip), envelope: { "mail" => tip.node_key, "text" => text },
          command: command(text, origin: tip.delegation? ? CHILD_ORIGIN : ORIGIN,
            sender_public_id: identity&.fetch("conversation_public_id", nil) || conversation.public_id,
            task_key: TaskResultEnvelope.call_key(tip, boundary: boundary), wake: tip.wake,
            callback_result: callback)
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
      def command(text, origin:, sender_public_id:, task_key:, wake:, callback_result: nil)
        passive = wake == "passive"
        Conversations::Inputs::Create::Command.kernel(
          host: conversation, acting_user: creating_user, kind: passive ? "message" : "direct_reply",
          entries: [{ "text" => text }], origin: origin,
          sender_conversation_public_id: sender_public_id,
          run_public_id: @run&.public_id,
          task_key: task_key,
          callback_result: callback_result,
          answering_user_public_id: answering_user.public_id,
          **(passive ? {} : surface)
        )
      end

      def surface = @surface ||= self.class.surface(@run)

      # Namespaced by the loop: every loop's keys start at `r1`, and the
      # receipt is scoped to the conversation, which hosts many loops.
      def receipt_key(tip) = "mail:#{@run.public_id}:#{tip.node_key}"

      # Guarded, not locked: `result_delivered_at` is not a status and two jobs racing
      # here both hold the same receipt.
      def stamp(tip)
        now = Time.current
        Task.where(id: tip.id, result_delivered_at: nil).update_all(result_delivered_at: now, updated_at: now)
        :delivered
      end

      def refused(key, refusal)
        Rails.logger.info(
          "event=run_mail_refused loop=#{@run&.public_id} " \
          "tip=#{key} reason=#{refusal.outcome}"
        )
        refusal.outcome
      end
  end
end
