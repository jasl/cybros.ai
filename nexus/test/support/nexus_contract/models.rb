module Nexus
  module Contract
    class << self
      private

        # THE MODEL PLANE (audit wire-22): what `GET /models` and the
        # `model_providers` doors serve, rendered by the two presenters
        # over a fixture provider and entry — never the compiled catalog,
        # which differs by environment. Four rows spell the four pricing
        # states the projection can take; a refused row carries the
        # resolver's own word; the lane row is the account's two facts.
        def models
          provider = { "api_format" => "openrouter_chat" }
          rates = { "input_per_mtok" => "0.3", "output_per_mtok" => "1.2" }
          priced = { "pricing" => { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only", "rates" => rates } },
                     "capabilities" => { "tool_calls" => true, "input_modalities" => %w[image] } }
          free = { "pricing" => { "account_unit" => "USD",
                                  "schedule" => { "kind" => "catalog_only",
                                                  "rates" => rates.transform_values { "0" } } } }
          model = ->(ref, entry, refusal: nil, account_unit: "USD", visible: true) do
            stringify_keys(AgentAPI::ModelPresenter.row(ref: ref, entry: entry, provider_id: "openrouter",
              provider: provider, refusal: refusal, account_unit: account_unit, visible: visible))
          end
          available = model.call("openrouter/fixture/priced", priced)
          unavailable = model.call("openrouter/fixture/priced", priced,
            refusal: ModelSelection::Resolver::CREDENTIAL_REFUSALS.fetch(:no_credential).to_s)
          known_free = model.call("openrouter/fixture/free", free)
          unmetered = model.call("openrouter/fixture/unmetered", {})
          cost_unknown = model.call("openrouter/fixture/priced", priced, account_unit: nil)
          shapes = [available, known_free, unmetered, cost_unknown]

          policy = Data.define(:enabled?, :lock_version).new(enabled?: true, lock_version: 3)
          credential = Data.define(:material_kind, :reauthorization_required?)
            .new(material_kind: "api_key", reauthorization_required?: false)
          # The pack's clock: the lane rows render at one fixed instant.
          now = Time.utc(2026, 8, 31, 0, 0, 0)
          lane = stringify_keys(AgentAPI::ModelProviderPresenter.row(
            provider_id: "openrouter", provider: provider, policy: policy, credential: credential,
            runtime_state: nil, models: 12, now: now
          ))
          # A lane that honestly needs no secret: `configured` on its own.
          free_lane = stringify_keys(AgentAPI::ModelProviderPresenter.row(
            provider_id: "dev", provider: provider.merge("credentials" => "none"), policy: nil, credential: nil,
            runtime_state: nil, models: 2, now: now
          ))
          # A lane under the provider's own floor (item 11): `unavailable_until`
          # is the ISO time the provider named, beside every other fact unchanged.
          floored = Data.define(:next_admission_at) do
            def floored?(at) = next_admission_at > at
          end.new(next_admission_at: Time.utc(2026, 8, 31, 0, 1, 0))
          floored_lane = stringify_keys(AgentAPI::ModelProviderPresenter.row(
            provider_id: "openrouter", provider: provider, policy: policy, credential: credential,
            runtime_state: floored, models: 12, now: now
          ))
          listing = { "models" => [available] }
          providers = { "model_providers" => [lane, free_lane, floored_lane] }

          {
            "workloads" => Nexus::ModelWorkloads::ALL.sort,
            "listing_envelope" => listing.keys,
            "list_filters" => %w[workload],
            "admin_list_filters" => %w[workload available],
            "row_projection" => available.keys,
            "capabilities_projection" => available.fetch("capabilities").keys,
            # The pricing block compacts: `state` always, the unit and the
            # two rates only where the state carries them.
            "pricing_projection" => shapes.map { |row| row.fetch("pricing").keys }.reduce(:|),
            "pricing_projection_required" => %w[state],
            "pricing_states" => shapes.map { |row| row.dig("pricing", "state") },
            # The resolver's own words, the ones the authoring door refuses with.
            "unavailable_reasons" => (ModelSelection::Resolver::CREDENTIAL_REFUSALS.values.map(&:to_s) + ["model_hidden"]).uniq.sort,
            "credentials" => ModelCatalog::ProfileBuilder::CREDENTIALS.values.uniq.sort,
            "providers_envelope" => providers.keys,
            "provider_singular_envelope" => %w[model_provider],
            "provider_projection" => lane.keys,
            "error_codes" => MODEL_ERROR_STATUSES.keys,
            "error_statuses" => MODEL_ERROR_STATUSES,
            "valid_fixture" => listing,
            "unavailable_fixture" => unavailable,
            "hidden_fixture" => model.call("openrouter/fixture/priced", priced, refusal: "model_hidden", visible: false),
            "known_free_fixture" => known_free,
            "unmetered_fixture" => unmetered,
            "cost_unknown_fixture" => cost_unknown,
            "valid_providers_fixture" => providers,
            "valid_provider_fixture" => { "model_provider" => lane },
            "floored_provider_fixture" => { "model_provider" => floored_lane },
            "authorization_session_fixture" => {
              "authorization_session" => stringify_keys(API::ModelProviderAuthorizationPresenter.session(
                ModelProviderOAuthSession.new(
                  public_id: "01900000-0000-7000-8000-000000000071", issuing_user_id: 71,
                  kind: "device_start", state: "pending", progress: "awaiting_user",
                  authorization_deadline_at: Time.utc(2026, 9, 29, 0, 15),
                  verification_uri: ModelProviders::CodexAuthorization.verification_url,
                  user_code: "TEST-CODE"
                ), user: User.new(id: 71))),
            },
            "valid_lane_request" => { "command" => { "enabled" => true, "expected_lock_version" => nil } },
            "valid_api_key_request" => { "command" => { "api_key" => "fixture-provider-key" } },
            "valid_error_fixture" =>
              api_error_fixture("model_plane_unavailable", MODEL_ERROR_STATUSES.fetch("model_plane_unavailable")),
            "unknown_unavailable_reason_fixture" => unavailable.merge("unavailable_reason" => UNKNOWN_VALUE_FIXTURE),
            "unknown_pricing_state_fixture" => available.merge("pricing" => { "state" => UNKNOWN_VALUE_FIXTURE }),
            "unknown_credentials_fixture" => lane.merge("credentials" => UNKNOWN_VALUE_FIXTURE),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_value_behavior" => "carry_unknown",
            "unknown_field_behavior" => "ignore",
          }
        end
    end
  end
end
