module AgentLoops
  module Spawn
    # Spawn creates a reusable child conversation, answered by the caller's
    # own profile with empty context or by a named peer. The initial brief is
    # the spawner's principal-authored Input. Conversation lifetime returns
    # replies through mail; turn lifetime owns only this original execution
    # through a DelegationTask. The optional finite wait controls the caller's
    # next round independently of that completion obligation.
    #
    # Launch is resumable: create the uniquely linked child, append completion
    # when turn-owned, append an optional await, then publish the brief. The
    # observations exist before any child can answer. Separate transactions
    # preserve Conversation -> Loop -> Input/task lock order. Publication
    # records the accepted Input UUID atomically under the source loop, so
    # stop fences late work and receipt expiry cannot rebrief a consumed input.
    class Run
      class Refused < StandardError; end

      EMPTY_PROMPT = "prompt is empty. Say what the conversation should do and what to answer with.".freeze
      INVALID_WAIT = KernelTool::INVALID_WAIT
      INVALID_LABEL = "label must be lowercase letters, digits, `_` or `-`, at most 64 characters.".freeze
      # The one sentence every conversation verb reads on a standalone loop.
      NO_CONVERSATION = format(ConversationTool::Run::NO_CONVERSATION, "spawn").freeze
      SIDE_SPAWNER = "a side conversation cannot spawn; spawn from the conversation it branched from.".freeze
      AWAIT_SUFFIX = "-spawn-1".freeze

      def self.call(node:) = new(node: node).call

      # The await's key: the call's namespace names the call, which is
      # the id the model reads back — the `task`/`ask` shape.
      def self.await_key(call_key) = "#{call_key}#{AWAIT_SUFFIX}"

      def initialize(node:)
        @node = node
      end

      def call
        agent_loop = @node.agent_loop
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_loop.graph_mutable?

        input = @node.tool_input
        refusal = refusal_for(agent_loop, input)
        return settle(refusal, is_error: true) if refusal

        child = child_for(agent_loop, input)
        if KernelTool.lifetime(@node, input) == "turn"
          @delegation = Delegations.prepare(call: @node)
          raise Refused, "The spawn was refused: delegation_canceled." unless @delegation
        end
        append_await(agent_loop, input) if wait?(input)
        post_brief(agent_loop, child, input)
        settle(started_text(child, input))
      rescue Refused => error
        Delegations.launch_failed(call: @node, detail: error.message)
        settle(error.message, is_error: true)
      end

      private

        def await_key = self.class.await_key(@node.node_key)
        def wait?(input) = KernelTool.wait?(input)
        # The profile whose engine made the call: the child's creator and,
        # without `agent`, its answerer. The loop's `creating_user` is the
        # SPEAKER and may be a Human.
        def spawner(agent_loop) = agent_loop.answering_user

        def refusal_for(agent_loop, input)
          return NO_CONVERSATION if agent_loop.standalone?
          return SIDE_SPAWNER if agent_loop.conversation.side?
          return EMPTY_PROMPT if String.try_convert(input["prompt"]).to_s.strip.empty?
          return INVALID_WAIT unless KernelTool.valid_wait?(input)
          return KernelTool::INVALID_LIFETIME unless KernelTool.valid_lifetime?(input)
          return KernelTool::INVALID_WAKE unless KernelTool.valid_wake?(input)
          if KernelTool.lifetime(@node, input) == "turn" && agent_loop.delivered?
            return "The spawn was refused: turn_already_delivered."
          end
          return INVALID_LABEL unless valid_label?(input["label"])

          KernelTool.model_refusal(agent_loop, input)
        end

        def valid_label?(label)
          word = label.to_s.strip.downcase
          word.empty? || (word.length <= 64 && word.match?(Conversation::SPAWN_LABEL_FORMAT))
        end

        # ── the child ──────────────────────────────────────────────────

        def child_for(agent_loop, input)
          existing = @node.spawned_conversation
          return existing if existing

          answerer = answerer_for(agent_loop, input)
          result = ApplicationRecord.transaction(requires_new: true) do
            Conversations::Create.call(Conversations::Create::Command.new(
              workspace: agent_loop.workspace, creating_user: spawner(agent_loop),
              title: nil, metadata: nil, billing_subject: nil,
              answering_user_public_id: answerer&.public_id,
              parent: agent_loop.conversation, spawn_node: @node, spawn_label: input["label"]
            ))
          end
          return result.value if result.accepted?

          raise Refused, create_refusal(result, input)
        rescue ActiveRecord::RecordNotUnique
          # A twin run minted the child first (the unique spawn link); read
          # the winner. Another call's child holding this label is the
          # label's own refusal.
          @node.reload.spawned_conversation || raise(Refused, label_taken(input))
        end

        # `agent` (WHO — `to` is a conversation on every verb) by
        # @handle or public id through the one resolver; absent is the
        # spawner itself. A name that is nobody's is answered with the
        # agents it could have named (the `tools` precedent) — `send`'s
        # `agent` reads the same sentence.
        def answerer_for(agent_loop, input)
          address = input["agent"]
          return nil if address.blank?

          user = User.members.addressed_by(agent_loop.workspace.account_id, address).first
          raise Refused, ConversationTool::Run.principal_unknown(agent_loop.workspace, address) if user.nil?

          user
        end

        def create_refusal(result, input)
          case result.outcome
          when :answerer_not_eligible
            "agent: #{input["agent"]} cannot answer a conversation here: it is not an agent profile " \
              "with write standing in this workspace."
          when :side_conversation then SIDE_SPAWNER
          when :invalid
            return label_taken(input) if result.record.errors.of_kind?(:spawn_label, :taken)

            "The spawn was refused: #{result.record.errors.full_messages.join("; ")}."
          else
            "The spawn was refused: #{result.outcome}."
          end
        end

        def label_taken(input)
          "label #{input["label"].to_s.strip.downcase.inspect} already names one of this conversation's " \
            "children; choose another."
        end

        # ── the await ──────────────────────────────────────────────────

        # A kernel-held await (`holder: :kernel`): tokened, so it parks
        # `dispatched` off every inbox and is never a person's question;
        # `absorb`, so its expiry runs the continuation with the detach
        # sentence; the default clock (1 h, clamped per park).
        def append_await(agent_loop, input)
          return if agent_loop.agent_loop_nodes.exists?(node_key: await_key)

          step = Tasks::Step::Ask.new(key: await_key, prompt: input["prompt"], on_failure: "absorb")
          # A graph-authored call has no provider pairing. Its wait and result
          # consumers follow the first reply, including non-model consumers.
          result = Tasks::Append.call(Tasks::Append::Command.kernel(
            agent_loop: agent_loop, steps: [step], tip: KernelTool.branch_tip(@node),
            origin: "kernel", expansion_parent: @node, holder: :kernel,
            head: (KernelTool.continuation_of(@node)&.node_key if @node.tool_call_id),
            replaces: (@node.node_key unless @node.tool_call_id)
          ))
          # A twin run appended it under the loop lock first.
          return if result.applied? || result.outcome == :duplicate_task_key

          detail = result.errors.first&.fetch("code", nil) || result.outcome
          raise Refused, "The spawn was refused: #{detail}."
        end

        # ── the brief ──────────────────────────────────────────────────

        # The child's first turn: the SPAWNER's own word (never a kernel
        # receipt), a reply head the answerer's engine answers — the
        # answerer's own preset first, else THE INITIATOR'S model the brief
        # carries (`KernelTool.initiator_model`: the call's `model`,
        # else the calling round's configured model) — carrying the
        # parent's stamp so the relay knows what the parent opened. Only
        # the selection crosses: the spawner's approval word and tool
        # narrowing never do; the child runs under its answerer's
        # whole declaration. The hosted receipt survives materialization or
        # deletion of the queued input, so a retried job posts ONE brief.
        def post_brief(agent_loop, child, input)
          return if @delegation&.delegated_input_public_id

          parent = agent_loop.conversation
          envelope = { "spawn" => child.public_id, "text" => input["prompt"] }
          result = ConversationCommandReceipt::Idempotent.call(
            account: agent_loop.account, workspace: agent_loop.workspace, acting_user: spawner(agent_loop),
            operation: :input_create, idempotency_key: "spawn:#{agent_loop.public_id}:#{@node.node_key}",
            host: child,
            request_digest: ConversationCommandReceipt.digest_for(operation: :input_create, envelope: envelope)
          ) do
            accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
              host: child, acting_user: spawner(agent_loop), kind: "direct_reply",
              entries: [{ "text" => input["prompt"] }], delivery_mode: "queue",
              sender_conversation_public_id: parent.public_id,
              agent_loop_public_id: agent_loop.public_id, task_key: @node.node_key,
              delegation: @delegation,
              **KernelTool.initiator_model(@node, input)
            ))
            next accepted unless accepted.accepted?

            ConversationCommandReceipt::Idempotent::Success.new(
              status: 202, body: { "input" => { "public_id" => accepted.value.public_id } }, host: child
            )
          end
          if result.outcome == :refused
            return if result.refusal.outcome == :delegation_published

            raise Refused, "The spawn was refused: #{result.refusal.outcome}."
          elsif result.outcome == :mismatched
            raise Refused, "The spawn was refused: idempotency_envelope_mismatch."
          end
        end

        # ── the answer ─────────────────────────────────────────────────

        def started_text(child, input)
          name = child.public_id.dup
          name << " (label #{child.spawn_label})" if child.spawn_label
          who = "@#{child.answering_user.handle}"
          if @delegation
            return "Spawned conversation #{name}, answered by #{who}; its result is owed before your final reply. " \
              "#{wait?(input) ? "Waiting for its first reply." : "Continue independent work while it runs."}"
          end
          return "Spawned conversation #{name}, answered by #{who}; waiting for its first reply." if wait?(input)
          if KernelTool.wake(@node, input) == "passive"
            return "Spawned conversation #{name}, answered by #{who}, in the background. " \
              "Its reply is recorded in your conversation history without starting another turn."
          end

          "Spawned conversation #{name}, answered by #{who}, in the background. Its reply reaches you as " \
            "<task_result task=\"#{@node.node_key}\" conversation=\"#{child.public_id}\"> in a later " \
            "message that is not from the person. send it more, read its status, or cancel it by that id."
        end

        def settle(text, is_error: false)
          text = "#{text}\n#{KernelTool.task_reference(@node)}" unless is_error
          KernelTool.settle(@node, text, is_error: is_error, title: is_error ? "spawn refused" : "spawn")
        end
    end
  end
end
