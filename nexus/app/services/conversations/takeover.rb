module Conversations
  # Human release of a spawned branch, retaining its execution and provenance.
  # The lifecycle root serializes tree changes. Run locks cover the real request
  # ownership closure; NOWAIT makes an unordered batch Stop a clean loser/winner
  # rather than a lock cycle. No mutation precedes acquisition of that whole set.
  class Takeover
    def self.call(...) = new(...).call

    def initialize(conversation:, acting_user:)
      @conversation, @acting_user = conversation, acting_user
    end

    def call
      return Outcome.refused(:not_authorized) unless @acting_user.human? && @conversation.writable_by?(@acting_user)

      ApplicationRecord.uncached do
        SubagentTree.with_root(@conversation) do |root|
          @root = root
          acquire_branch
          refusal = precondition
          next Outcome.refused(refusal) if refusal
          next Outcome.accepted(@conversation) if @conversation.taken_over_at

          prepare_requests
          next Outcome.refused(:conflicting_request_owner) if conflicting_owner?

          acquire_links
          acquire_owners
          next Outcome.refused(:source_stopped) if stopped?
          next Outcome.refused(:conversation_busy) unless prepare_settlements

          complete_release
          Outcome.accepted(@conversation)
        end
      end
    rescue ActiveRecord::LockWaitTimeout
      # Rescue outside the transaction: even a partially acquired owner set
      # must be released before returning a retryable conflict to the Human.
      Outcome.refused(:conversation_busy)
    end

    private

      def acquire_branch
        # A child consumer can already hold one of these rows while waiting for
        # a source Run. Never wait for it while holding another branch row.
        @branch = SubagentTree.members(@conversation).order(:id).lock("FOR UPDATE NOWAIT").to_a
        @conversation = @branch.find { |row| row.id == @conversation.id }
        @branch_ids = @branch.map(&:id)
        @previous = SubagentTree.members(@root).where.not(id: @branch_ids)
      end

      def precondition
        return :not_found if @conversation.tombstoned?
        return :not_authorized unless @conversation.writable_by?(@acting_user)
        return :conversation_archived if @branch.any?(&:archived?)
        return :not_subagent if @conversation.parent_conversation_public_id.nil? || @conversation.schedule_public_id || @conversation.side?

        nil
      end

      def prepare_requests
        @inputs = Input.where(host_type: "Conversation", host_id: @branch_ids, source_released_at: nil)
          .where.not(sender_run_public_id: nil).where("communication_kind IS DISTINCT FROM 'message'")
        @turns = Turn.where(conversation_id: @branch_ids, source_released_at: nil, forked_from_turn_public_id: nil)
          .where.not(sender_run_public_id: nil).where("communication_kind IS DISTINCT FROM 'message'")
        @live_runs = Run.where(variant_id: Variant.where(turn_id: Turn.where(conversation_id: @branch_ids).select(:id)).select(:id))
          .where(status: Run::LIVE_STATUSES)
        @live_turns = @turns.where(status: Turn::ACTIVE_STATUSES)
          .or(@turns.where(id: Variant.where(id: @live_runs.select(:variant_id)).select(:turn_id)))
        @incoming_inputs = @inputs.where(sender_conversation_public_id: @previous.select(:public_id))
        @incoming_turns = @turns.where(sender_conversation_public_id: @previous.select(:public_id))
      end

      def conflicting_owner?
        tree = SubagentTree.members(@root).select(:public_id)
        @inputs.where.not(sender_conversation_public_id: tree).or(@inputs.where(sender_conversation_public_id: nil)).exists? ||
          @live_turns.where.not(sender_conversation_public_id: tree).or(@live_turns.where(sender_conversation_public_id: nil)).exists?
      end

      def acquire_owners
        # Sources can only lose upstream edges while we wait; they cannot gain
        # new ones. Branch locks prevent new target work. A fresh check after
        # this acquisition therefore covers every still-effective owner.
        seeds = [@live_runs, Run.where(public_id: @inputs.select(:sender_run_public_id)),
          Run.where(public_id: @live_turns.select(:sender_run_public_id))]
          .map { |scope| scope.select(:id, :variant_id).to_sql }.join(" UNION ")
        sql = <<~SQL
          WITH RECURSIVE owners AS (
            (#{seeds})
            UNION
            SELECT source.id, source.variant_id FROM owners child
            JOIN variants variant ON variant.id = child.variant_id
            JOIN turns turn ON turn.id = variant.turn_id
            LEFT JOIN variants origin ON origin.id = variant.origin_variant_id
            JOIN runs source ON source.public_id = turn.sender_run_public_id
            WHERE turn.source_released_at IS NULL AND turn.forked_from_turn_public_id IS NULL
              AND turn.communication_kind IS DISTINCT FROM 'message'
              AND (variant.position = 0 OR (variant.source = 'fallback' AND origin.position = 0))
          ) SELECT id FROM owners
        SQL
        # Completed executions still own pending reports, even when no target
        # Run is live. Include those actual writers in the same ordered set.
        requests = "#{@incoming_inputs.select(:public_id).to_sql} UNION #{@incoming_turns.select(:input_public_id).to_sql}"
        @completions = Task.where(type: Tasks::DelegationTask.sti_name).where("delegated_input_public_id IN (#{requests})")
        completion_owners = @completions.where.not(status: Task::TERMINAL_STATUSES).select(:run_id).to_sql
        message_owners = Run.where(public_id: @messages.select(:expected_steering_run_public_id)).select(:id).to_sql
        owner_ids = Run.lease_connection.select_values("#{sql} UNION #{completion_owners} UNION #{message_owners}")
        owners = Run.where(id: owner_ids)
        @owners = owners.order(:id).lock("FOR NO KEY UPDATE NOWAIT").index_by(&:id)
        @owners_by_public_id = @owners.values.index_by(&:public_id)
      end

      def acquire_links
        crossing = ConversationLink.active.where(first_conversation_id: @branch_ids, second_conversation_id: @previous.select(:id))
          .or(ConversationLink.active.where(second_conversation_id: @branch_ids, first_conversation_id: @previous.select(:id)))
        @links = crossing.order(:id).lock("FOR UPDATE NOWAIT").to_a
        @messages = Input.where(communication_kind: "message").where(conversation_link_id: @links.map(&:id))
          .or(Input.where(communication_kind: "message", host_type: "Conversation", host_id: @branch_ids,
            sender_conversation_public_id: @previous.select(:public_id)))
      end

      def stopped?
        return true if @live_runs.any? { |run| run.stopped? || run.canceling? || Runs::SourceWork.stopped_source?(run) }
        return true if @inputs.any? do |input|
          source = @owners_by_public_id[input.sender_run_public_id]
          Runs::SourceWork.stopped?(input.sender_run_public_id, source)
        end
        return true if @live_turns.any? do |turn|
          variant = Runs::Delegations.answering_variant(turn)
          variant && Runs::SourceWork.stopped_variant_source?(variant)
        end

        # Branch cancellation may end only the completion, not its whole Run.
        active_inputs = @inputs.select(:public_id)
        active_turns = @live_turns.select(:input_public_id)
        @completions.where(status: %w[canceled skipped])
          .where(delegated_input_public_id: active_inputs)
          .or(@completions.where(status: %w[canceled skipped]).where(delegated_input_public_id: active_turns)).exists?
      end

      def prepare_settlements
        @nodes = @completions.where.not(status: Task::TERMINAL_STATUSES).to_a
        @calls = @nodes.map { |node| @owners.fetch(node.run_id).tasks.find_by!(node_key: node.node_key.delete_suffix(Runs::Delegations::SUFFIX)) }
        # Publication precedes observer dispatch. Let the ordinary scheduler
        # cross that dependency before settling; never bypass its queued guard.
        @nodes.none? { |node| node.status == "queued" } && @calls.none? { |call| call.spawn_await&.status == "queued" }
      end

      def complete_release
        messages = @messages.order(:id).lock("FOR UPDATE NOWAIT").to_a
        # All Task locks precede all result-body writes, including a multi-request
        # takeover. The source Run already serializes every graph writer.
        Task.where(id: @nodes.map(&:id) + @calls.filter_map { |call| call.spawn_await&.id }).order(:id).lock.load
        request_ids = @nodes.map(&:delegated_input_public_id)
        hosts = @incoming_inputs.where(public_id: request_ids).pluck(:public_id, :host_id).to_h
          .merge(@incoming_turns.where(input_public_id: request_ids).pluck(:input_public_id, :conversation_id).to_h)
        branch = @branch.index_by(&:id)
        now = Time.current
        ConversationLink.where(id: @links.map(&:id)).update_all(closed_at: now, close_reason: "taken_over", updated_at: now)
        @incoming_inputs.update_all(source_released_at: now)
        @incoming_turns.update_all(["source_released_at = ?, relayed_at = COALESCE(relayed_at, ?)", now, now])
        @conversation.take_over(by: @acting_user, at: now)
        @nodes.zip(@calls).each do |node, call|
          node.association(:run).target = @owners.fetch(node.run_id)
          child = branch.fetch(hosts.fetch(node.delegated_input_public_id))
          turn = Runs::Delegations.original_turn(child, call)
          variant = Runs::Delegations.answering_variant(turn)
          moved = Runs::Delegations::Settlement.call_locked(node: node, call: call, child: child,
            text: "The user took over this conversation. Its work continues independently; you no longer need to wait for its result.",
            status: "completed", execution_identity: {
              "status" => "completed", "outcome" => "taken_over", "conversation_public_id" => child.public_id,
              "input_public_id" => node.delegated_input_public_id, "turn_public_id" => turn&.public_id,
              "variant_public_id" => variant&.public_id, "run_public_id" => variant&.run&.public_id,
              "taken_over_by_public_id" => @acting_user.public_id, "taken_over_at" => now.iso8601(6),
            })
          raise "published request could not settle during takeover" unless moved
        end
        messages.each { |input| Inputs::Destroy.remove(input) }
        @links.each do |link|
          link.reload.narrate(acting_user: @acting_user)
        end
        Event::Append.call(host: @conversation, items: [{ type: "conversation_taken_over", payload: {
          "conversation_public_id" => @conversation.public_id,
          "parent_conversation_public_id" => @conversation.parent_conversation_public_id,
          "taken_over_by_public_id" => @acting_user.public_id, "taken_over_at" => now.iso8601(6),
        } }])
      end
  end
end
