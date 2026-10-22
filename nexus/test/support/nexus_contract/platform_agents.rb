module Nexus
  module Contract
    class << self
      private

        def platform_agents
          configuration = profiles.fetch("agent_api").fetch("configuration")
          measured_at = Time.iso8601("2026-10-15T00:00:00Z")
          document = PromptDocument.new(slot: "system_prompt", role: "system", version: 2,
            content: "Help {{user}} with their task.", bytesize: "Help {{user}} with their task.".bytesize,
            updated_at: measured_at)
          agent_type = Data.define(:public_id, :handle, :display_name, :status, :agent_identifier,
            :named_agent_scope, :description, :derived_from, :updated_at, :prompt_documents,
            *configuration.keys.map(&:to_sym)) do
              def agent_member? = true
            end
          agent = agent_type.new(
            public_id: "01900000-0000-7000-8000-000000000020", handle: "fixture-agent", display_name: "Fixture agent",
            status: "active", agent_identifier: "fixture.agent", named_agent_scope: nil, description: nil,
            derived_from: nil, updated_at: measured_at,
            prompt_documents: [document], **configuration.symbolize_keys
          )
          address = Data.define(:public_id, :agent, :status, :last_seen_at, :connected_at,
            :presence_connection_id, :presence_server_id).new(
              public_id: "01900000-0000-7000-8000-000000000023", agent: agent, status: "active",
              last_seen_at: measured_at, connected_at: measured_at, presence_connection_id: nil, presence_server_id: nil
            )
          key_type = Struct.new(:public_id, :name, :note, :credential_plane, :created_at, :last_used_at, :revoked_at,
            keyword_init: true) do
            def member_plane? = credential_plane == "member"
            def usable? = revoked_at.nil?
            def executor_usable? = revoked_at.nil?
          end
          key = key_type.new(public_id: "01900000-0000-7000-8000-000000000022", name: "Fixture key",
            note: nil, credential_plane: "member", created_at: Time.iso8601("2026-10-15T00:00:00Z"),
            last_used_at: nil, revoked_at: nil)
          agent_row = stringify_keys(API::AgentPresenter.basic(agent))
          connection = stringify_keys(API::AgentPresenter.application_connection(address,
            credential_readiness: :ready, live_server_ids: []))
          member_key = stringify_keys(API::APIKeyPresenter.basic(key))
          key.credential_plane = "executor_transport"
          executor_key = stringify_keys(API::APIKeyPresenter.basic(key))
          {
            "valid_agent_fixture" => { "agent" => agent_row },
            "valid_agent_detail_fixture" => { "agent" => agent_row.merge("application_connection" => connection) },
            "valid_agent_configuration_fixture" => stringify_keys(API::AgentPresenter.configuration(agent, measured_at: measured_at)),
            "valid_agents_fixture" => { "agents" => [agent_row], "pagination" => { "next_after" => nil } },
            "valid_member_keys_fixture" => { "api_keys" => [member_key], "pagination" => { "next_after" => nil } },
            "valid_executor_keys_fixture" => { "api_keys" => [executor_key], "pagination" => { "next_after" => nil } },
            "valid_member_key_grant_fixture" => { "api_key" => member_key, "secret" => "fixture-member-api-key" },
            "valid_executor_key_grant_fixture" => { "api_key" => executor_key, "secret" => "fixture-executor-api-key" },
            "valid_key_revocation_fixture" => { "status" => 204, "body" => nil },
            "unknown_agent_status_fixture" => { "agent" => agent_row.merge("status" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_key_plane_fixture" => { "api_key" => member_key.merge("plane" => UNKNOWN_VALUE_FIXTURE),
              "secret" => "fixture-unclassified-api-key" },
            "unknown_status_behavior" => "carry_unknown", "unknown_key_plane_behavior" => "reject_response",
          }
        end
    end
  end
end
