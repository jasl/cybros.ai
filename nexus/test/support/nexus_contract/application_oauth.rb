module Nexus
  module Contract
    class << self
      private

        def application_oauth
          connector = oauth
          login = {
            "access_token" => "fixture-platform-token", "plane" => "platform",
            "refresh_token" => "fixture-platform-refresh-token", "token_type" => "Bearer",
            "expires_in" => AccessToken::OAUTH_TTL.to_i, "scope" => OAuth::APPLICATION_SCOPE,
            "user" => { "public_id" => "01900000-0000-7000-8000-000000000001",
              "display_name" => "Fixture operator", "role" => "owner" },
          }
          runtime = login.merge(
            "agent_public_id" => "01900000-0000-7000-8000-000000000020",
            "agent" => connector.fetch("valid_agent_token_fixture"),
            "runner" => connector.fetch("valid_runner_token_fixture")
          )
          {
            "client_id" => OAuth::APPLICATION_CLIENT_ID,
            "scope" => OAuth::APPLICATION_SCOPE,
            "grant_types" => [OAuth::CODE_GRANT_TYPE, OAuth::DEVICE_GRANT_TYPE, OAuth::REFRESH_GRANT_TYPE].sort,
            "code_exchange_request" => { "client_id" => OAuth::APPLICATION_CLIENT_ID,
              "grant_type" => OAuth::CODE_GRANT_TYPE, "code" => "fixture-code",
              "redirect_uri" => "http://127.0.0.1:49152/callback", "code_verifier" => "v" * 43 },
            "device_authorization_request" => { "client_id" => OAuth::APPLICATION_CLIENT_ID,
              "scope" => OAuth::APPLICATION_SCOPE, "connection_mode" => "login" },
            "refresh_token_request" => { "client_id" => OAuth::APPLICATION_CLIENT_ID,
              "grant_type" => OAuth::REFRESH_GRANT_TYPE, "refresh_token" => "fixture-platform-refresh-token" },
            "valid_login_only_fixture" => login,
            "valid_runtime_fixture" => runtime,
            "valid_refresh_fixture" => login.merge("access_token" => "fixture-rotated-platform-token",
              "refresh_token" => "fixture-rotated-platform-refresh-token"),
            "unknown_plane_fixture" => login.merge("plane" => UNKNOWN_VALUE_FIXTURE),
            "unknown_scope_fixture" => login.merge("scope" => UNKNOWN_VALUE_FIXTURE),
            "unknown_token_type_fixture" => login.merge("token_type" => UNKNOWN_VALUE_FIXTURE),
            "unknown_child_plane_fixture" => runtime.merge("agent" => runtime.fetch("agent").merge("plane" => UNKNOWN_VALUE_FIXTURE)),
            "unknown_role_fixture" => login.merge("user" => login.fetch("user").merge("role" => UNKNOWN_VALUE_FIXTURE)),
            "unknown_authority_behavior" => "reject_response",
            "unknown_role_behavior" => "carry_unknown",
            "ambiguous_rotation_behavior" => "authorization_lost_without_retry",
            "refresh_lineage_behavior" => "independent_primary_agent_runner",
          }
        end
    end
  end
end
