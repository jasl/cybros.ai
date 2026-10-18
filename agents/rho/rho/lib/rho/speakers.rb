module Rho
  # The application owner is a conversation participant, independent of the
  # Agent credential that submits their words. Every ingress uses this identity.
  module Speakers
    def self.owner(client:, agent_public_id:)
      client.profile.register_ingress_speaker(channel_key: "rho:#{agent_public_id}",
        external_id: "owner", display_name: "Owner")
    end

    def self.memory_context(audience: "owner")
      raise ArgumentError, "unknown Bot audience" unless BotSettings::AUDIENCES.include?(audience)

      bindings = [
        { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
        { "name" => "speaker", "scope" => "speaker", "access" => "read_write" },
      ]
      bindings << { "name" => "agent", "scope" => "agent", "access" => "read_write" } if audience == "owner"
      bindings << { "name" => "workspace", "scope" => "workspace", "access" => audience == "external" ? "read" : "read_write" }
      { "bindings" => bindings }
    end
  end
end
