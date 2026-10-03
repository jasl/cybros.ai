# One browser ceremony, three consequence shapes (an agent plus runner grant
# keeps the agent wording), and one word for what is connecting. The confirm
# page, the settled page, and every flash in between name the same subject, or
# the steward is asked to verify a thing one surface calls a runner and the next
# calls an agent program.
module OAuth::DeviceHelper
  def device_grant_subject(grant)
    if grant.tools_provider_connection?
      "tools provider"
    elsif grant.runner_only_connection?
      "runner"
    else
      "agent program"
    end
  end

  # The heading word for a machine's kind — the runners console's own word
  # (`RunnersHelper`), read off the kind the grant requested.
  def device_grant_machine_label(grant)
    machine_kind_label(grant.requested_executor_kind) if grant.runner_only_connection?
  end
end
