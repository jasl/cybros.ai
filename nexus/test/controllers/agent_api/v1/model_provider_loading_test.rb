require "test_helper"

class AgentAPI::V1::ModelProviderLoadingTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: users(:member), name: "Provider metadata")
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @account.reload
    @policy = create_model_policy
    @credential = ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "test_api", api_key: "sk-loading-test"
    ).credential
  end

  test "provider listing reads lane metadata without loading model definitions or credential material" do
    oauth = ModelProviderCredential.create!(
      account: @account, provider_id: "codex_subscription", material_kind: "oauth_tokens",
      secret: "access-token", refresh_secret: "refresh-token",
      provider_account_identity: "provider-account",
      authorization_lineage_id: SecureRandom.uuid_v7, expires_at: 2.hours.from_now,
      reauthorization_required: true, reauthorization_reason: "refresh_token_invalidated"
    )

    reads = capture_payload_reads do
      get "/agent_api/v1/model_providers", headers: auth
    end

    assert_response :success
    rows = response.parsed_body.fetch("model_providers").index_by { |row| row.fetch("id") }
    assert_equal [true, true, "api_key", @policy.lock_version],
      rows.fetch("test_api").values_at("enabled", "configured", "material_kind", "lock_version")
    assert_equal [false, true, "oauth_tokens", true],
      rows.fetch(oauth.provider_id).values_at("enabled", "configured", "material_kind", "reauthorization_required")
    assert_equal ModelCatalog.current.models.keys.count { |ref| ref.start_with?("test_api/") } + @overlay_refs.length,
      rows.fetch("test_api").fetch("models"), "counts are configured refs without loading their payloads"
    assert_equal 0, reads.fetch(:policy_bytes), "metadata listing loaded #{reads.inspect}"
    assert_equal 0, reads.fetch(:credential_bytes), "metadata listing loaded #{reads.inspect}"
  end

  test "model listing reads the overlay once for composition and no second time for credential gates" do
    reads = capture_payload_reads do
      get "/agent_api/v1/models", headers: auth
    end

    assert_response :success
    rows = response.parsed_body.fetch("models").index_by { |row| row.fetch("ref") }
    @overlay_refs.each do |ref|
      assert rows.fetch(ref).fetch("available")
      assert_equal "priced", rows.fetch(ref).dig("pricing", "state")
    end
    assert_equal 1, reads.fetch(:policy_reads),
      "composition needs the definitions once; credential gates loaded #{reads.inspect}"
  end

  test "the key command returns lane metadata without reloading its model definitions" do
    generation = @credential.generation
    operator = create_access_token_fixture(user: users(:owner), name: "Operator", plane: :platform)
    reads = capture_payload_reads do
      put "/api/v1/admin/model_providers/test_api/api_key",
        params: { command: { api_key: "sk-loading-rotated" } }, as: :json,
        headers: { "Authorization" => "Bearer #{operator.secret}" }
    end

    assert_response :success
    row = response.parsed_body.fetch("model_provider")
    assert_equal [true, true, "api_key", @policy.lock_version],
      row.values_at("enabled", "configured", "material_kind", "lock_version")
    assert_equal generation + 1, @credential.reload.generation
    assert_equal "sk-loading-rotated", @credential.secret
    assert_equal 0, reads.fetch(:policy_bytes), "the command's presenter loaded #{reads.inspect}"
  end

  test "credential resolution checks enablement without model definitions and retains the signing material" do
    resolved = nil
    reads = capture_payload_reads do
      resolved = ModelProviders::CredentialResolver.resolve(
        account: @account, provider_id: "test_api", credential_lane: "api_key",
        total_execution_deadline_seconds: 600, now: Time.current
      )
    end

    assert_predicate resolved, :resolved?
    assert_equal @credential.public_id, resolved.credential.public_id
    assert_equal @credential.generation, resolved.credential.generation
    assert_equal "sk-loading-test", resolved.credential.secret
    assert_equal 0, reads.fetch(:policy_bytes), "the enabled gate loaded #{reads.inspect}"
  end

  private

    def auth = { "Authorization" => "Bearer #{@token.secret}" }

    def create_model_policy
      # A deployment may keep distinct named model configurations. These are
      # complete catalog entries, with no filler and well below the 2 MiB cap.
      model = ModelCatalog.current.models.fetch("test_api/text")
      @overlay_refs = Array.new(128) { |index| "test_api/team-#{index}" }
      entries = @overlay_refs.each_with_index.to_h do |ref, index|
        [ref, { "op" => "upsert", "model" => model.merge(
          "model_id" => "text", "display_name" => "Team model #{index}"
        ) }]
      end
      policy = ModelProviderConfig.create!(
        account: @account, provider_id: "test_api", enabled: true,
        model_overrides: {
          "schema_version" => ModelProviderConfig::OVERRIDES_SCHEMA_VERSION,
          "entries" => entries,
        }
      )
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, "test_api")
      assert_empty @overlay_refs - catalog.models.keys, "the fixture must compose as actual usable model definitions"
      policy
    end

    def capture_payload_reads
      connection = ApplicationRecord.lease_connection
      select_all = connection.method(:select_all)
      reads = { policy_reads: 0, policy_bytes: 0, credential_bytes: 0 }
      connection.clear_query_cache

      connection.stub(:select_all, lambda { |*arguments, **options|
        executed = false
        subscriber = ->(*, payload) do
          # Count bytes returned from the database, not repeated references to
          # the same query-cache result while listing models on one provider.
          executed = true if !payload[:cached] && payload[:sql].match?(
            /FROM "model_provider_(?:configs|credentials)"/
          )
        end
        result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          select_all.call(*arguments, **options)
        end
        if executed
          if (position = result.columns.index("model_overrides"))
            reads[:policy_reads] += result.rows.length
            reads[:policy_bytes] += result.rows.sum { |row| row.fetch(position).to_s.bytesize }
          end
          %w[secret refresh_secret provider_account_identity].each do |column|
            if (position = result.columns.index(column))
              reads[:credential_bytes] += result.rows.sum { |row| row.fetch(position).to_s.bytesize }
            end
          end
        end
        result
      }) { yield }
      reads
    end
end
