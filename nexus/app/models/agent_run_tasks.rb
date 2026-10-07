# The node-kind namespace: four kinds are authored as verbs, the join is
# the barrier the kernel places, and delegation observes a child execution.
module AgentRunTasks
  # The clocked parks: the timeout sweep's frontier and the pause clock-shift
  # select the same types.
  PARKED_TYPES = %w[AgentRunTasks::AwaitTask AgentRunTasks::ToolTask].freeze

  module_function

  def type_for_kind(kind)
    case kind
    when "model_task" then AgentRunTasks::ModelTask
    when "tool_task" then AgentRunTasks::ToolTask
    when "await_task" then AgentRunTasks::AwaitTask
    when "join_task" then AgentRunTasks::JoinTask
    when "delegation_task" then AgentRunTasks::DelegationTask
    else nil
    end
  end
end
