# The node-kind namespace: four kinds are authored as verbs, the join is
# the barrier the kernel places, and delegation observes a child execution.
module Tasks
  # The clocked parks: the timeout sweep's frontier and the pause clock-shift
  # select the same types.
  PARKED_TYPES = %w[Tasks::AwaitTask Tasks::ToolTask].freeze

  module_function

  def type_for_kind(kind)
    case kind
    when "model_task" then Tasks::ModelTask
    when "tool_task" then Tasks::ToolTask
    when "await_task" then Tasks::AwaitTask
    when "join_task" then Tasks::JoinTask
    when "delegation_task" then Tasks::DelegationTask
    else nil
    end
  end
end
