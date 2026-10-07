require_relative "conversation_fixtures"

module CybrosAgentTest
  module RewindFixtures
    include ConversationFixtures

    def evidence(runners = [effect("runner-a")], status: "touched", reason: nil)
      { "status" => status, "runners" => runners, "reason" => reason }.compact
    end

    def effect(runner, checkpoint: { "hash" => "tree", "store" => "store-a" })
      { "runner_executor_public_id" => runner, "run_public_id" => "source-run", "task_key" => "write",
        "checkpoint" => checkpoint }
    end

    def fork_reply(effects = evidence)
      { "conversation" => contract.fetch("valid_fixture").fetch("conversation"), "runner_effects" => effects }
    end

    def tool_reply(content: nil, error: nil, metadata: nil)
      { "task" => { "key" => "call_tool", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto",
        "status" => "completed", "result" => { "is_error" => !error.nil? }, "output" => error,
        "structured_content" => content, "metadata" => metadata }.compact }
    end

    def tool_responses(detail = tool_reply(metadata: { "checkpoint" => { "hash" => "undo" } }))
      run = { "public_id" => "restore-run", "status" => "running", "tasks" => [] }
      [[201, {}, { "run" => run, "receipt" => {} }], [200, {}, { "run" => run }], [200, {}, detail]]
    end
  end
end
