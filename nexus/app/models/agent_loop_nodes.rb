# The node-kind namespace: four kinds are authored as verbs, the join is
# the barrier the kernel places, and delegation observes a child execution.
module AgentLoopNodes
  # The clocked parks: the timeout sweep's frontier and the pause clock-shift
  # select the same types.
  PARKED_TYPES = %w[AgentLoopNodes::AwaitTask AgentLoopNodes::ToolTask AgentLoopNodes::ScriptTask].freeze

  module_function

  def type_for_kind(kind)
    case kind
    when "model_task" then AgentLoopNodes::ModelTask
    when "tool_task" then AgentLoopNodes::ToolTask
    when "await_task" then AgentLoopNodes::AwaitTask
    when "script_task" then AgentLoopNodes::ScriptTask
    when "join_task" then AgentLoopNodes::JoinTask
    when "delegation_task" then AgentLoopNodes::DelegationTask
    else nil
    end
  end
end
