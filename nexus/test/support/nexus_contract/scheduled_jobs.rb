module Nexus
  module Contract
    class << self
      private

        def scheduled_jobs
          full, execution = scheduled_job_fixtures
          intent = full.slice("name", "prompt", "rule", "model", "configuration", "tool_names", "approval_mode",
            "answering_user_public_id", "speaker_actor_public_id", "source_agent_loop_public_id", "source_task_key")
          {
            "statuses" => ScheduledJob::STATUSES,
            "rule_kinds" => ScheduledJob::Rule::KINDS,
            "interval_seconds" => { "minimum" => ScheduledJob::Rule::INTERVAL_SECONDS.begin,
              "maximum" => ScheduledJob::Rule::INTERVAL_SECONDS.end },
            "projection" => full.keys,
            "execution_projection" => execution.keys,
            "valid_fixture" => { "scheduled_job" => full },
            "valid_list_fixture" => { "scheduled_jobs" => [full], "pagination" => { "next_after" => nil } },
            "valid_create_request" => { "scheduled_job" => intent },
            "valid_update_request" => { "scheduled_job" => { "expected_lock_version" => 2, "prompt" => "Report progress" } },
            "valid_executions_fixture" => { "executions" => [execution],
              "pagination" => { "next_after" => nil, "last_cursor" => "scheduled-execution-tail" } },
            "unknown_status_fixture" => { "scheduled_job" => full.merge("status" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_rule_fixture" => { "scheduled_job" => full.merge("rule" => { "kind" => UNKNOWN_VALUE_FIXTURE }) },
            "unknown_field_behavior" => "ignore",
          }
        end

        def scheduled_job_fixtures
          now = Time.utc(2026, 10, 2, 9)
          child = Conversation.new(public_id: "01999000-0000-7000-8000-000000000004",
            scheduled_input_public_id: "01999000-0000-7000-8000-000000000005", scheduled_for: now, created_at: now)
          turn = ConversationTurn.new(public_id: "01999000-0000-7000-8000-000000000006", status: "completed")
          agent_loop = AgentLoop.new(public_id: "01999000-0000-7000-8000-000000000007", status: "completed")
          execution = stringify_keys(ScheduledJobs::ExecutionProjection.basic(child: child, input: nil,
            turn: turn, agent_loop: agent_loop))
          job = ScheduledJob.new(public_id: "01999000-0000-7000-8000-000000000001",
            conversation: Conversation.new(public_id: "01999000-0000-7000-8000-000000000002"),
            creating_user: User.new(public_id: "01999000-0000-7000-8000-000000000003"),
            answering_user: User.new(public_id: "01999000-0000-7000-8000-000000000008"),
            name: "Morning summary", prompt: "Summarize unread email", status: "active", lock_version: 2,
            rule: { "kind" => "daily", "local_time" => "09:00", "time_zone" => "Asia/Shanghai" },
            provider_id: "dev", model_ref: "mock-text", reasoning_effort: "medium", configuration: {},
            tool_names: [], approval_mode: nil, source_agent_loop_public_id: nil, source_task_key: nil,
            next_run_at: now + 1.day, last_enqueued_at: now, last_input_public_id: child.scheduled_input_public_id,
            last_execution_conversation_id: 91, created_at: now - 1.day, updated_at: now)
          [stringify_keys(AgentAPI::ScheduledJobPresenter.basic(job, executions: { 91 => execution })), execution]
        end
    end
  end
end
