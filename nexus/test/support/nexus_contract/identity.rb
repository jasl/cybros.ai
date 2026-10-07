module Nexus
  module Contract
    class << self
      private

        def credentials
          {
            "planes" => AccessToken.credential_planes.keys.sort,
            "prefixes" => {
              "access_token" => AccessToken::DIGESTED.prefix,
              "api_session" => Session::DIGESTED.prefix,
              "device_code" => DeviceAuthorization::DIGESTED.prefix,
              "member_recovery" => MemberRecoveryAuthorization::DIGESTED.prefix,
              "refresh_token" => RefreshToken::DIGESTED.prefix,
            },
            "wrong_plane_behavior" => "401 without explanation",
          }
        end

        def oauth
          token_planes = AccessToken.credential_planes.keys & %w[member executor_transport]
          valid_agent_token = {
            "access_token" => "fixture-member-token",
            "plane" => "member",
            "executor_access_token" => "fixture-executor-token",
            "refresh_token" => "fixture-refresh-token",
            "token_type" => "Bearer",
            "expires_in" => AccessToken::OAUTH_TTL.to_i,
          }
          valid_runner_token = {
            "access_token" => "fixture-executor-token",
            "plane" => "executor_transport",
            "refresh_token" => "fixture-refresh-token",
            "token_type" => "Bearer",
            "expires_in" => AccessToken::OAUTH_TTL.to_i,
          }
          # The combined grant's body (r-modes M2): the member-led agent
          # bundle plus the nested runner lineage — present only on a
          # combined consume, never on rotation.
          valid_combined_token = valid_agent_token.merge(
            "runner" => {
              "access_token" => "fixture-runner-token",
              "refresh_token" => "fixture-runner-refresh-token",
            }
          )

          {
            "client_id" => OAuth::DEVICE_CLIENT_ID,
            "grant_types" => [OAuth::DEVICE_GRANT_TYPE, OAuth::REFRESH_GRANT_TYPE].sort,
            "token_planes" => token_planes.sort,
            "token_type" => "Bearer",
            "error_envelope" => %w[error],
            "error_statuses" => OAUTH_ERROR_STATUSES,
            "terminal_error_codes" => %w[access_denied expired_token invalid_grant],
            "agent_authorization_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "agent_identifier" => "fixture-agent",
              "agent_display_name" => "Fixture agent",
              "executor_display_name" => "Fixture executor",
            },
            "runner_authorization_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "registration_identifier" => "fixture-runner",
              "runner_display_name" => "Fixture runner",
              "executor_kind" => TaskExecutor::MACHINE_KINDS.first,
            },
            "device_token_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "grant_type" => OAuth::DEVICE_GRANT_TYPE,
              "device_code" => "fixture-device-code",
            },
            "refresh_token_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "grant_type" => OAuth::REFRESH_GRANT_TYPE,
              "refresh_token" => "fixture-refresh-token",
            },
            "cancellation_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "device_code" => "fixture-device-code",
            },
            "revocation_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "token" => "fixture-access-token",
            },
            "valid_device_authorization_fixture" => {
              "device_code" => "fixture-device-code",
              "user_code" => "BCDF-GHJK",
              "verification_uri" => "https://nexus.example/oauth/device",
              "verification_uri_complete" =>
                "https://nexus.example/oauth/device?user_code=BCDF-GHJK",
              "expires_in" => DeviceAuthorization::TTL.to_i,
              "interval" => DeviceAuthorization.default_interval,
            },
            "valid_agent_token_fixture" => valid_agent_token,
            "valid_runner_token_fixture" => valid_runner_token,
            "valid_combined_token_fixture" => valid_combined_token,
            "valid_cancellation_fixture" => { "status" => 200, "body" => nil },
            "consumed_cancellation_fixture" => oauth_error_fixture("too_late"),
            "valid_revocation_fixture" => { "status" => 200, "body" => nil },
            "valid_error_fixture" => oauth_error_fixture("authorization_pending"),
            "terminal_error_fixture" => oauth_error_fixture("access_denied"),
            "unknown_client_request" => {
              "client_id" => UNKNOWN_VALUE_FIXTURE,
            },
            "unknown_grant_request" => {
              "client_id" => OAuth::DEVICE_CLIENT_ID,
              "grant_type" => UNKNOWN_VALUE_FIXTURE,
            },
            "unknown_plane_fixture" => valid_agent_token.merge("plane" => UNKNOWN_VALUE_FIXTURE),
            "unknown_token_type_fixture" =>
              valid_agent_token.merge("token_type" => UNKNOWN_VALUE_FIXTURE),
            "unknown_error_fixture" => {
              "status" => 400,
              "headers" => {},
              "body" => { "error" => UNKNOWN_VALUE_FIXTURE },
            },
            "unknown_field_behavior" => "ignore",
          }
        end

        def sessions
          session = {
            "public_id" => "01900000-0000-7000-8000-000000000010",
            "kind" => "api",
            "expires_at" => "2026-08-29T00:00:00Z",
          }
          valid_create = {
            "session" => session,
            "token" => "fixture-session-token",
            "token_type" => "Bearer",
          }

          {
            "kinds" => Session.kinds.keys.sort,
            "error_statuses" => SESSION_ERROR_STATUSES,
            "valid_create_fixture" => valid_create,
            "valid_show_fixture" => { "session" => session },
            "valid_revoke_fixture" => { "revoked" => true },
            "valid_error_fixture" => api_error_fixture("invalid_credentials", 401),
            "unknown_kind_fixture" => {
              "session" => session.merge("kind" => UNKNOWN_VALUE_FIXTURE),
            },
            "unknown_token_type_fixture" =>
              valid_create.merge("token_type" => UNKNOWN_VALUE_FIXTURE),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_kind_behavior" => "carry_unknown",
            "unknown_token_type_behavior" => "reject_response",
            "unknown_field_behavior" => "ignore",
          }
        end

        def contract_ingress_speaker
          Speaker.new(public_id: "01900000-0000-7000-8000-0000000000a8", kind: "ingress",
            channel_key: "bridge:123", external_id: "456", display_name: "External Ada", user: contract_agent)
        end

        def profiles
          agent_api = {
            "member" => {
              "public_id" => "01900000-0000-7000-8000-000000000020",
              "handle" => "lark",
              "kind" => "agent",
              "role" => "member",
              "display_name" => "Fixture agent",
            },
            "credential" => {
              "plane" => "member",
              "expires_at" => "2026-08-13T00:00:00Z",
            },
            "configuration" => {
              "tool_definitions" => [Nexus::ToolRegistry.function_definition("nexus.graph.delegate_task")],
              "kernel_tools" => [],
              "runner_executor_public_ids" => [],
              "runner_tool_names" => nil,
              "approval_mode" => "bypass",
              # The fifth column: the rule list under the one grammar — a deny rule with a path and
              # a reason, an allow rule over the kernel tools.
              "approval_rules" => [
                { "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny",
                  "reason" => "a person can run it" },
                { "tool" => "memory_*|ask|task", "verdict" => "allow" },
              ],
              "prompt_mechanism" => "default",
              "prompt_template" => nil,
              "compaction_policy" => { "mode" => "kernel" },
              "lifecycle_hooks" => nil,
              # The seventh column: the profile's own model, a catalog ref the producer test's
              # account runs (the dev lane).
              "default_model" => "dev/mock-text",
              # The ninth: the model a step it answers re-runs on once when a provider's
              # classifier declined it — judged as the seventh is.
              "fallback_model" => "dev/mock-unmetered",
            },
            "measured_at" => "2026-07-30T00:00:00Z",
          }
          platform_session = {
            "member" => {
              "public_id" => "01900000-0000-7000-8000-000000000021",
              "kind" => "human",
              "role" => "owner",
            },
            "credential_plane" => nil,
          }

          {
            "agent_api" => agent_api,
            "valid_ingress_speaker_fixture" => { "ingress_speaker" => AgentAPI::IngressSpeakerPresenter.detail(contract_ingress_speaker) },
            "approval_modes" => User::AgentConfiguration::APPROVAL_MODES,
            "approval_rule_keys" => Executors::Rules::KEYS,
            "approval_verdicts" => Executors::Rules::VERDICTS,
            "platform_api_session" => platform_session,
            "platform_api_token" => platform_session.merge("credential_plane" => "platform"),
            "unknown_member_kind_fixture" => agent_api.merge(
              "member" => agent_api.fetch("member").merge("kind" => UNKNOWN_VALUE_FIXTURE)
            ),
            "unknown_member_role_fixture" => agent_api.merge(
              "member" => agent_api.fetch("member").merge("role" => UNKNOWN_VALUE_FIXTURE)
            ),
            "unknown_credential_plane_fixture" => agent_api.merge(
              "credential" =>
                agent_api.fetch("credential").merge("plane" => UNKNOWN_VALUE_FIXTURE)
            ),
            "unknown_platform_credential_plane_fixture" =>
              platform_session.merge("credential_plane" => UNKNOWN_VALUE_FIXTURE),
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
            "unknown_field_behavior" => "ignore",
            "alias_render_fixture" => agent_api.merge(
              "configuration" => agent_api.fetch("configuration").merge("tool_definitions" => alias_render)
            ),
            # THE NAMED DEFINITIONS LISTING: the caller's own rows and the steward's other published
            # ones, each rendered through the real presenter — the principals row plus scope, name,
            # description, declarer and the configuration block whole.
            "definition_scopes" => User.definition_scopes.keys,
            "named_agents_fixture" => named_agents_fixture,
            "unknown_named_agent_scope_fixture" => {
              "agents" => [named_agents_fixture.fetch("agents").first.merge("scope" => UNKNOWN_VALUE_FIXTURE)],
            },
          }
        end

        # Rendered through the REAL presenter with duck-typed stand-ins: the
        # pack's agent (`lark`) declared `reviewer` as an instance row, and a
        # sibling instance published `docs` under the same steward.
        def named_agents_fixture
          steward_type = Data.define(:public_id)
          declarer_type = Data.define(:public_id, :agent_identifier)
          row_type = Data.define(
            :public_id, :handle, :kind, :display_name, :agent_identifier, :steward, :derived_from,
            :definition_scope, :definition_name, :description,
            :tool_definitions, :kernel_tools, :runner_executor_public_ids, :runner_tool_names,
            :approval_mode, :approval_rules, :prompt_mechanism, :prompt_template,
            :compaction_policy, :default_model, :lifecycle_hooks, :fallback_model
          )
          steward = steward_type.new(public_id: "01900000-0000-7000-8000-000000000003")
          lark = declarer_type.new(public_id: "01900000-0000-7000-8000-000000000020", agent_identifier: "rho.7f3a9c1e")
          sibling = declarer_type.new(public_id: "01900000-0000-7000-8000-000000000022", agent_identifier: "rho.19c0aa77")
          reviewer = row_type.new(
            public_id: "01900000-0000-7000-8000-000000000030", handle: "reviewer", kind: "agent",
            display_name: "reviewer", agent_identifier: "rho.7f3a9c1e/reviewer", steward: steward, derived_from: lark,
            definition_scope: "instance", definition_name: "reviewer",
            description: "Reviews a diff for defects and reports only what matters; use it after a change lands.",
            tool_definitions: [Nexus::ToolRegistry.function_definition("nexus.graph.delegate_task")],
            kernel_tools: [], runner_executor_public_ids: [], runner_tool_names: nil,
            approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default", prompt_template: nil,
            compaction_policy: { "mode" => "kernel" }, default_model: "dev/mock-text", lifecycle_hooks: nil,
            fallback_model: "dev/mock-unmetered"
          )
          docs = row_type.new(
            public_id: "01900000-0000-7000-8000-000000000031", handle: "docs", kind: "agent",
            display_name: "docs", agent_identifier: "rho.19c0aa77/docs", steward: steward, derived_from: sibling,
            definition_scope: "steward", definition_name: "docs",
            description: "Writes the docs for a change and answers with the paths it wrote.",
            tool_definitions: [], kernel_tools: [], runner_executor_public_ids: [], runner_tool_names: [],
            approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default",
            prompt_template: nil, compaction_policy: nil, default_model: nil, lifecycle_hooks: nil,
            fallback_model: nil
          )
          { "agents" => [docs, reviewer].map { |row| stringify_keys(AgentAPI::ProfilePresenter.named_definition(row)) } }
        end

        def users
          {
            "kinds" => User.kinds.keys.sort,
            "roles" => (User.roles.keys - ["system"]).sort,
            "statuses" => User.statuses.keys.sort,
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
          }
        end

        def admin_users
          user = {
            "public_id" => "01900000-0000-7000-8000-000000000040",
            "kind" => "human",
            "role" => "member",
            "status" => "removed",
            "display_name" => "Removed fixture member",
          }

          {
            "removal_envelope" => %w[user],
            "user_projection" => user.keys,
            "error_codes" => ADMIN_USER_ERROR_STATUSES.keys,
            "error_statuses" => ADMIN_USER_ERROR_STATUSES,
            "valid_removal_fixture" => { "user" => user },
            "valid_error_fixture" => api_error_fixture(
              "workspace_ownership_transfer_required",
              ADMIN_USER_ERROR_STATUSES.fetch("workspace_ownership_transfer_required")
            ),
            "unknown_status_fixture" => {
              "user" => user.merge("status" => UNKNOWN_VALUE_FIXTURE),
            },
            "unknown_kind_fixture" => {
              "user" => user.merge("kind" => UNKNOWN_VALUE_FIXTURE),
            },
            "unknown_role_fixture" => {
              "user" => user.merge("role" => UNKNOWN_VALUE_FIXTURE),
            },
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
            "unknown_field_behavior" => "ignore",
          }
        end
    end
  end
end
