module CybrosAgent
  module Api
    module ScheduledJobProjections
      include WorkspaceProjections

      SHAPES = {
        ScheduledJobRule => {
          kind: :string, run_at: :optional_string, every_seconds: :optional_integer,
          starts_at: :optional_string, local_time: :optional_string, time_zone: :optional_string,
        },
        ScheduledJobModel => { model: :string, reasoning_effort: :optional_string },
        ScheduledJobExecution => {
          child_conversation_public_id: :string, input_public_id: :optional_string,
          turn_public_id: :optional_string, agent_loop_public_id: :optional_string,
          scheduled_for: :string, status: :string, created_at: :string,
        },
        ScheduledJob => {
          public_id: :string, name: :optional_string, prompt: :string, rule: [:shape, ScheduledJobRule],
          model: [:optional_shape, ScheduledJobModel], configuration: :optional_json_object,
          tool_names: :optional_string_list, approval_mode: :optional_string,
          answering_user_public_id: :optional_string, speaker_actor_public_id: :optional_string,
          status: :string, lock_version: :integer, next_run_at: :optional_string,
          last_enqueued_at: :optional_string, last_input_public_id: :optional_string, last_error_code: :optional_string,
          last_execution: [:optional_shape, ScheduledJobExecution],
          source_agent_loop_public_id: :optional_string, source_task_key: :optional_string,
          conversation_public_id: :optional_string, creating_user_public_id: :optional_string,
          created_at: :optional_string, updated_at: :optional_string,
        },
        ScheduledJobExecutionPage => {
          items: [:shapes, ScheduledJobExecution, "executions"],
          next_after: [:nullable_string, "pagination", "next_after"],
          last_cursor: [:nullable_string, "pagination", "last_cursor"],
        },
      }.freeze
    end
  end
end
