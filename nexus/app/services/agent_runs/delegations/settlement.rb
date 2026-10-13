module AgentRuns
  module Delegations
    # Caller holds the source loop. Result publication, wait read replacement
    # and graph release commit together; a short wait never owns completion.
    class Settlement
      def self.call(...) = new(...).call

      def initialize(node:, call:, text:, status:, error_key: nil, child: nil)
        @node, @call, @text, @status, @error_key, @child = node, call, text, status, error_key, child
      end

      def call
        @node.lock!
        return false if @node.terminal?
        return false if @status == "completed" && @node.status == "queued"

        await = @call.spawn_await
        # A queued wait has not yet crossed the launch dependency. Successful
        # reports wait for dispatch; refused launches cancel this empty wait.
        return false if @status == "completed" && await&.status == "queued"

        await&.lock!
        replace_wait_reads(await) if await && !await.terminal?
        settle_wait(await) if await && !await.terminal?
        publish
        Release.settled(await) if await&.terminal?
        Release.settled(@node)
        EvaluateQuiescence.call(@node.agent_run)
        ScheduleJob.perform_later(@node.agent_run_id)
        true
      end

      private

        def replace_wait_reads(await)
          # An expired wait still contributes its timeout; the actual report
          # later reaches the caller through the ordinary detached-result wake.
          return if await.started? && await.deadline_passed?

          Tasks::Append.replace_reads(agent_run: @node.agent_run,
            replaces: await.node_key, reads: [@node.node_key])
        end

        def settle_wait(await)
          if await.status == "queued"
            Transition.node(await, status: "canceled", completed_at: Time.current,
              error_key: @error_key, failure_resolution: "canceled")
          else
            result = Parks::Settle.settle_locked(node: await, content: @text,
              outcome: @status == "completed" ? "completed" : "failed",
              resolved_by: (@child && { "kind" => "conversation", "public_id" => @child.public_id }))
            # This resolver owns the child's one final report. Unlike a
            # person's oversized answer, it will not be resubmitted, so a
            # storage refusal must close the wait before releasing completion.
            unless result.moved? || await.terminal?
              FailNode.call(agent_run: @node.agent_run, node: await,
                error_key: "delegation_result_unstorable", error_detail: result.outcome,
                worklist: [], release: false)
            end
          end
        end

        def publish
          result = ContentBodies::Replace.call(owner: @node, role: "output",
            entries: [{ "text" => @text }], readable_text: @text, seal: true)
          if result.accepted?
            StampOutputPreview.call(@node)
            Transition.node(@node, status: @status, completed_at: Time.current,
              error_key: @error_key, error_detail: (@text.first(256) unless @status == "completed"))
          else
            Transition.node(@node, status: "failed", completed_at: Time.current,
              error_key: "delegation_result_unstorable", error_detail: result.refusal.to_s)
          end
        end
    end
  end
end
