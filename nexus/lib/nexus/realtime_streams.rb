module Nexus
  # Public-id stream names shared by subscribers and publishers. Action Cable's
  # record-based stream_for would key by database identity instead.
  module RealtimeStreams
    module_function

    # The public execution resource is Run; its internal Rails model is AgentRun.
    def resource_type(host)
      name = host.model_name.singular
      name == "agent_run" ? "run" : name
    end

    def resource(resource_type, public_id, feed)
      "agent_api:v1:#{resource_type}:#{public_id}:#{feed}"
    end

    def executor_inbox(executor_public_id)
      "agent_api:v1:executor:#{executor_public_id}:inbox"
    end
  end
end
