module Runs
  module Spawn
    # Spawn prepares completion and an optional finite await, then publishes
    # its original brief. A linked spawn commits child, link and brief together.
    # Every lifetime owns the original execution through a DelegationTask:
    # turn lifetime requires its
    # report before final delivery; conversation lifetime can mail it afterward.
    # The optional wait controls the caller's next round independently.
    # Publication retains the Input UUID under its source Run, so Stop fences
    # late work and receipt expiry cannot rebrief a consumed input.
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
        run = @node.run
        return :not_running unless @node.status == "running"
        return :not_mutable unless run.graph_mutable?

        input = @node.tool_input
        refusal = refusal_for(run, input)
        return settle(refusal, is_error: true) if refusal

        prepare_observers(run, input)
        if input["establish_link"]
          answerer = answerer_for(run, input) || spawner(run)
          Conversations::Links::Create.with_authority(workspace: run.workspace, agents: [spawner(run), answerer]) do
            Conversations::SubagentTree.with_root(run.conversation) do |root|
              run.conversation.lock! unless root.id == run.conversation.id
              child = child_for(run, input)
              grant = Conversations::Links::Create.call_locked(conversation: run.conversation.reload, agent: spawner(run),
                peer_conversation: child, peer_agent: child.answering_user, acting_user: spawner(run))
              raise Refused, "The spawn was refused: #{grant.outcome}." unless grant.accepted?

              raise ActiveRecord::Rollback unless post_brief(run, child, input, link: grant.value)
              grant.value.narrate(acting_user: spawner(run)) if grant.value.previously_new_record?
            end
          end
        else
          child = child_for(run, input)
          post_brief(run, child, input)
        end
        :applied
      rescue Refused => error
        Delegations.launch_failed(call: @node, detail: error.message)
        settle(error.message, is_error: true)
      end

      private

        def wait?(input) = KernelTool.wait?(input)
        # The profile whose engine made the call: the child's creator and,
        # without `agent`, its answerer. The loop's `creating_user` is the
        # SPEAKER and may be a Human.
        def spawner(run) = run.answering_user

        def refusal_for(run, input)
          return NO_CONVERSATION if run.standalone?
          return SIDE_SPAWNER if run.conversation.side?
          return EMPTY_PROMPT if String.try_convert(input["prompt"]).to_s.strip.empty?
          return INVALID_WAIT unless KernelTool.valid_wait?(input)
          return "establish_link must be true or false." unless [nil, true, false].include?(input["establish_link"])
          return KernelTool::INVALID_LIFETIME unless KernelTool.valid_lifetime?(input)
          return KernelTool::INVALID_WAKE unless KernelTool.valid_wake?(input)
          if KernelTool.lifetime(@node, input) == "turn" && run.delivered?
            return "The spawn was refused: turn_already_delivered."
          end
          return INVALID_LABEL unless valid_label?(input["label"])

          catalog = run.execution_configuration&.delegation_catalog
          if catalog.nil?
            return "No delegation catalog is declared; omit declaration to spawn by agent identity." if input["declaration"].present?

            KernelTool.model_refusal(run, input)
          else
            names = catalog.map(&:name)
            @catalog_entry = catalog.find { |entry| entry.name == input["declaration"] }
            if input["agent"].present? || @catalog_entry.nil?
              available = names.empty? ? "no declarations are available" : "available declarations: #{names.join(", ")}"
              "Choose one declaration by name without agent; #{available}."
            else
              @declaration = Declaration.for(node: @node, entry: @catalog_entry, input: input, catalog: catalog)
              "model is required: this declaration has no default; select a concrete provider/model for this task." unless @declaration
            end
          end
        end

        def valid_label?(label)
          word = label.to_s.strip.downcase
          word.empty? || (word.length <= 64 && word.match?(Conversation::SPAWN_LABEL_FORMAT))
        end

        # ── the child ──────────────────────────────────────────────────

        def child_for(run, input)
          existing = @node.spawned_conversation
          return existing if existing

          answerer = answerer_for(run, input)
          parent = run.conversation
          # Birth and tree archive/unarchive share the lifecycle root: neither
          # command may miss a child committed after its descendant snapshot.
          # The one Conversation lock precedes child FK inserts; no Run is held.
          result = Conversations::SubagentTree.with_root(parent, requires_new: true) do |root|
            parent.reload unless parent == root
            next Outcome.refused(:not_found) if parent.tombstoned?

            Conversations::Create.call(Conversations::Create::Command.new(
              workspace: run.workspace, creating_user: spawner(run),
              title: nil, metadata: nil, billing_subject: nil,
              answering_user_public_id: answerer&.public_id,
              default_runner_executor_public_id: input.fetch("default_runner_executor_public_id") {
                Executors::TaskOperations::Context.defaults(@node).dig("environment", "default_runner_executor_public_id")
              },
              parent: parent, spawn_node: @node, spawn_label: input["label"],
              conversation_reach: [Conversations::Reach.of(@node), @declaration&.configuration&.conversation_reach].include?("subtree") ? "subtree" : "workspace",
              **(@declaration&.defaults || { agent_configuration: AgentConfiguration.capture(answerer || run.answering_user,
                executor_contexts: Executors::TaskOperations::Context.defaults(@node)["executor_contexts"]) })
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
        def answerer_for(run, input)
          address = input["agent"]
          return nil if address.blank?

          user = User.members.addressed_by(run.workspace.account_id, address).first
          raise Refused, ConversationTool::Run.principal_unknown(run.workspace, address) if user.nil?

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

        def prepare_observers(run, input)
          # Splice the finite wait before adding its independent completion;
          # otherwise a graph-authored spawn makes completion wait on itself.
          # Both appends share the source owner so a refused completion leaves
          # no await behind. Child birth and brief publication hold no Run here.
          run.with_lock(requires_new: true) do
            if wait?(input)
              result = Delegations::Observers.append_await(call: @node, prompt: input["prompt"])
              raise Refused, "The spawn was refused: #{result.outcome}." unless result.accepted?
            end
            @delegation = Delegations.prepare(call: @node, lifetime: KernelTool.lifetime(@node, input),
              wake: KernelTool.wake(@node, input))
            raise Refused, "The spawn was refused: delegation_canceled." unless @delegation
          end
        end

        # ── the brief ──────────────────────────────────────────────────

        # The brief is the spawner's own input, with the parent's stamp for
        # relay. A selected declaration carries its captured configuration
        # and effective selection, including reasoning. Identity-based spawn
        # retains the addressee's ordinary configured-model ladder. The call's
        # result survives input collection, so a retried job posts one brief.
        def post_brief(run, child, input, link: nil)
          accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
            host: child, acting_user: spawner(run), kind: "direct_reply",
            entries: [{ "text" => input["prompt"] }], delivery_mode: "queue", communication_kind: "request",
            sender_conversation_public_id: run.conversation.public_id,
            run_public_id: run.public_id, task_key: @node.node_key, delegation: @delegation,
            **brief_selection(input)
          )) do |row|
            receipt = { "input_public_id" => row.public_id, "conversation_public_id" => child.public_id,
              "answering_user_public_id" => row.answering_user.public_id, "state" => row.state,
              "delivery_mode" => row.delivery_mode, "link_public_id" => link&.public_id,
              "completion" => { "run_public_id" => run.public_id, "task_key" => @delegation.node_key } }
            result = KernelTool.settle(@node, "#{started_text(child, input)}\n#{KernelTool.task_reference(@node)}",
              title: "spawn", structured_content: receipt, locked: true)
            raise Refused, result.to_s unless %i[applied idle].include?(result)
          end
          return true if accepted.accepted?
          return false if accepted.outcome == :communication_published

          raise Refused, "The spawn was refused: #{accepted.outcome}."
        end

        def brief_selection(input) = @declaration ? @declaration.input_fields : KernelTool.initiator_model(@node, input)

        # ── the answer ─────────────────────────────────────────────────

        def started_text(child, input)
          name = child.public_id.dup
          name << " (label #{child.spawn_label})" if child.spawn_label
          who = "@#{child.answering_user.handle}"
          if @delegation.lifetime == "turn"
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
