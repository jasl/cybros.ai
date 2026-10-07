module AgentRuns
  module Parks
    # The caller holds the loop lock and has established that this unclaimed
    # park's addressee is being removed. An approval keeps its human door.
    class Revoke
      ERROR_KEY = "executor_revoked".freeze
      ERROR_DETAIL = "the executor this call was addressed to was removed before it took the call".freeze
      APPROVAL_DETAIL = "the agent application this approval was addressed to was removed; " \
        "a person with write standing on the workspace decides it".freeze

      def self.call(agent_run:, node:)
        if node.held?
          Transition.node(node, addressed_executor_id: nil, addressed_role: nil)
          AgentRun::Narration.record(agent_run, [{
            type: "task_readdressed",
            payload: {
              "task_key" => node.node_key,
              "role" => nil,
              "executor_public_id" => nil,
              "deadline_at" => node.deadline_at.iso8601,
              "detail" => APPROVAL_DETAIL,
            },
          }])
        else
          FailNode.call(
            agent_run: agent_run, node: node, worklist: [],
            error_key: ERROR_KEY, error_detail: ERROR_DETAIL
          )
        end
      end
    end
  end
end
