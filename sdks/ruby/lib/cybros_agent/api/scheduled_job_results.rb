module CybrosAgent
  module Api
    ScheduledJobRule = Data.define(:kind, :run_at, :every_seconds, :starts_at, :local_time, :time_zone) do
      def initialize(run_at: nil, every_seconds: nil, starts_at: nil, local_time: nil, time_zone: nil, **) = super
      def to_h = super.compact
    end

    ScheduledJobModel = Data.define(:model, :reasoning_effort) do
      def initialize(reasoning_effort: nil, **) = super
      def to_h = super.compact
    end

    # Execution status is the ordinary child conversation's current state;
    # completing a one-time schedule does not say its execution has finished.
    ScheduledJobExecution = Data.define(:child_conversation_public_id, :input_public_id, :turn_public_id,
      :agent_loop_public_id, :scheduled_for, :status, :created_at) do
      def initialize(input_public_id: nil, turn_public_id: nil, agent_loop_public_id: nil, **) = super
      def to_h = super.compact
    end

    ScheduledJob = Data.define(:public_id, :name, :prompt, :rule, :model, :configuration, :tool_names,
      :approval_mode, :answering_user_public_id, :speaker_actor_public_id, :status, :lock_version,
      :next_run_at, :last_enqueued_at, :last_input_public_id, :last_error_code, :last_execution,
      :source_agent_loop_public_id, :source_task_key, :conversation_public_id, :creating_user_public_id,
      :created_at, :updated_at) do
      def initialize(name: nil, model: nil, configuration: nil, tool_names: nil, approval_mode: nil,
                     answering_user_public_id: nil, speaker_actor_public_id: nil, next_run_at: nil,
                     last_enqueued_at: nil, last_input_public_id: nil, last_error_code: nil, last_execution: nil,
                     source_agent_loop_public_id: nil, source_task_key: nil, conversation_public_id: nil,
                     creating_user_public_id: nil, created_at: nil, updated_at: nil, **) = super
      def to_h = super.merge(rule: rule.to_h, model: model&.to_h, last_execution: last_execution&.to_h)
    end

    ScheduledJobExecutionPage = Data.define(:items, :next_after, :last_cursor)
  end
end
