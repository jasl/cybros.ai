module Runs
  module Delegations
    # The relay's source frontier and child hints reach the same owner. Its
    # target is the published input or position-zero execution, never today's
    # child head.
    class Converge
      def self.call(child:, call: child.spawn_node) = new(child, call).call

      def initialize(child, call)
        @child, @call = child, call
      end

      def call
        # Only a published request owns a completion; ordinary messages never
        # enter this path. Repeat the owner lookup under the child lock.
        return false unless @call && Delegations.for_call(@call)

        @child.with_lock do
          @call.reload

          @node = Delegations.for_call(@call)
          next false unless @node

          @turn = Delegations.original_turn(@child, @call)
          @variant = Delegations.answering_variant(@turn)
          @execution = @variant&.run
          @source = @call.run
          # Source and target are independent execution arbiters. Acquire their
          # existing ids in one order, after the child Conversation, before any
          # input/task/body or invocation lock used by publication and cleanup.
          [@source, @execution].compact.uniq(&:id).sort_by(&:id).each(&:lock!)
          @node.association(:run).target = @source
          @node.reload
          converge
        end
      end

      private

        def converge
          # Release is a durable request fact, independent of the source's
          # result retention and of any Stop that arrived after takeover.
          released = if @turn
            @turn.source_released_at
          else
            @child.inputs.where(public_id: @node.delegated_input_public_id).pick(:source_released_at)
          end
          if released
            false
          elsif SourceWork.stopped?(@source.public_id, @source)
            cleanup
          elsif %w[completed failed].include?(@node.status)
            false
          elsif %w[canceled skipped].include?(@node.status) || !@source.graph_mutable?
            cleanup
          elsif @turn
            converge_execution
          elsif @node.delegated_input_public_id &&
              !@child.inputs.exists?(public_id: @node.delegated_input_public_id)
            settle("The delegated input was removed before execution.", "failed", "delegation_abandoned")
          elsif @node.delegated_input_public_id.nil? && @call.terminal?
            settle("The spawn ended before its input was published.", "failed", "delegation_launch_failed")
          else
            false
          end
        end

        def converge_execution
          if @execution
            if @execution.delivered?
              text = @execution.deliverable_node&.output_body&.effective_text
              settle(text.presence || "(the delegated execution completed with no text)", "completed")
            elsif @execution.terminal?
              superseded = @execution.overridden?
              detail = superseded ? replacement_text : "The delegated execution ended #{@execution.status}."
              settle(detail, "failed", superseded ? "delegation_replaced" : "delegation_canceled")
            elsif @execution.needs_attention? && @execution.overridden?
              Stop.stop_now(@execution)
              false
            else
              false
            end
          else
            converge_invocation
          end
        end

        # The WORK's status, not the call's: a declined answer completed its
        # call and failed the reply, so the parent reads the refusal.
        def converge_invocation
          invocation = @variant&.model_invocation
          return false unless invocation&.terminal?
          return false if invocation.undecided?

          if invocation.work_status == "completed"
            text = invocation.content_bodies.find_by(role: "response")&.effective_text
            settle(text.presence || "(the delegated execution completed with no text)", "completed")
          elsif invocation.declined?
            settle(RefusalSentence.for_reply(invocation), "failed", ModelInvocation::DECLINED_KEY)
          elsif invocation.finish_error?
            settle(invocation.failure_detail, "failed", invocation.failure_reason_key)
          else
            settle("The delegated execution ended #{invocation.status}: #{invocation.failure_reason_key}.",
              "failed", "delegation_#{invocation.status}")
          end
        end

        def replacement_text
          "The delegated execution was replaced by answer #{@turn.active_variant.public_id}; " \
            "the original execution was stopped."
        end

        def settle(text, status, error_key = nil)
          moved = Settlement.call(node: @node, call: @call, child: @child,
            text: text, status: status, error_key: error_key,
            execution_identity: { "conversation_public_id" => @child.public_id, "input_public_id" => @node.delegated_input_public_id,
              "turn_public_id" => @turn&.public_id, "variant_public_id" => @variant&.public_id,
              "run_public_id" => @execution&.public_id,
              "status" => error_key == "delegation_canceled" ? "canceled" : status })
          @turn&.stamp_relayed if moved
          moved
        end

        def cleanup
          input = @child.inputs.find_by(public_id: @node.delegated_input_public_id)
          if input
            input.lock!
            Conversations::Inputs::Destroy.remove(input)
            @child.wake_drain
          elsif @execution && !@execution.stopped?
            Stop.stop_now(@execution)
          elsif (invocation = @variant&.model_invocation) && !invocation.terminal?
            # Invocation cancellation follows the same lock ladder as ordinary
            # turn cancel and never targets a later sample of the same Turn.
            invocation.with_lock { invocation.terminalize(status: "canceled", reason_key: "delegation_canceled") }
            Conversations::Turns::ConvergeJob.perform_later(@child.id)
          end
          @turn&.stamp_relayed
          true
        end
    end
  end
end
