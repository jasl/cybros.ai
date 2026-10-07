require "test_helper"
require Rails.root.join("db/seeds/import_environment_credentials").to_s

# Environment credential import runs through the seed entry point in deployed
# installations as well as development. Test seeds must never read real keys,
# and importing credentials must preserve the operator's policy decisions.
class ModelProviders::ImportEnvironmentCredentialsTest < ActiveSupport::TestCase
  # THE SCRUB LIST AND THE IMPORT LIST ARE ONE OBJECT, deliberately. The
  # predecessor kept them in two files, gained a seventh provider in only one
  # of them, and let a real xAI key reach its own test run through dotenv.
  # Iterating the seed helper's own map is what makes that impossible here.
  setup do
    @account = accounts(:cybros)
    @env = ModelProviders::ImportEnvironmentCredentials::ENV_KEYS.values.index_with { nil }
  end

  test "a declared provider with a key gets a credential and an enabled lane" do
    result = import("ANTHROPIC_API_KEY" => "sk-ant-test-material")

    assert_equal :applied, result.outcomes.fetch("anthropic")
    credential = ModelProviderCredential.find_by(account_id: @account.id, provider_id: "anthropic")
    assert_equal "api_key", credential.material_kind
    assert_equal "sk-ant-test-material", credential.secret
    assert_predicate ModelProviderConfig.find_by(account_id: @account.id, provider_id: "anthropic"), :enabled
  end

  test "production seeds import credentials without choosing a cost unit" do
    assert_nil @account.reload.cost_unit

    seed("production", "ANTHROPIC_API_KEY" => "sk-ant-production-test-material")

    credential = ModelProviderCredential.find_by(account_id: @account.id, provider_id: "anthropic")
    assert_not_nil credential
    assert_equal "sk-ant-production-test-material", credential.secret
    assert_predicate ModelProviderConfig.find_by(account_id: @account.id, provider_id: "anthropic"), :enabled
    assert_nil @account.reload.cost_unit
  end

  test "production seeds preserve an operator's cost unit" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "EUR")

    seed("production", "XAI_API_KEY" => "xai-production-test-material")

    assert_equal "EUR", @account.reload.cost_unit
    credential = ModelProviderCredential.find_by(account_id: @account.id, provider_id: "xai")
    assert_not_nil credential
    assert_equal "xai-production-test-material", credential.secret
  end

  test "seeds in every environment leave a fresh installation uninitialized" do
    Account.destroy_all

    %w[production development test].each do |environment|
      assert_no_difference ["Account.count", "User.count", "ModelProviderCredential.count"] do
        seed(environment, "ANTHROPIC_API_KEY" => "sk-ant-production-test-material")
      end
    end
  end

  test "a missing key is passed over rather than failing the seed" do
    result = import

    assert_equal [:absent], result.outcomes.values.uniq
    assert_empty ModelProviderCredential.where(account_id: @account.id, provider_id: "anthropic")
  end

  test "re-importing the same material changes nothing" do
    import("XAI_API_KEY" => "xai-test-material")
    before = ModelProviderCredential.find_by(account_id: @account.id, provider_id: "xai")

    result = import("XAI_API_KEY" => "xai-test-material")

    assert_equal :noop, result.outcomes.fetch("xai")
    assert_equal before.generation, before.reload.generation
  end

  # THE KILL SWITCH THAT UNDOES ITSELF. An operator who disables a lane and
  # then runs `db:seed` for an unrelated reason must not find it back on.
  test "production seeds do not re-enable a lane an operator disabled" do
    import("XAI_API_KEY" => "xai-test-material")
    policy = ModelProviderConfig.find_by(account_id: @account.id, provider_id: "xai")
    ModelProviders::DisableLane.call(
      account: @account, provider_id: "xai", expected_lock_version: policy.lock_version
    )

    seed("production", "XAI_API_KEY" => "xai-test-material")

    assert_not_predicate policy.reload, :enabled,
      "re-seeding overturned somebody's decision"
  end

  test "development seeds import keys without choosing the account cost unit" do
    assert_nil @account.reload.cost_unit

    seed("development", "XAI_API_KEY" => "xai-test-material")

    assert_nil @account.reload.cost_unit
    assert_equal "xai-test-material", ModelProviderCredential.find_by!(account: @account, provider_id: "xai").secret
  end

  test "a provider the catalog does not declare is never given a credential" do
    current = ModelCatalog.current
    without_openai = ModelCatalog::Snapshot.new(
      providers: current.providers.except("openai_api"),
      models: current.models, selectors: current.selectors
    )

    ModelCatalog.stub(:current, without_openai) do
      result = import("OPENAI_API_KEY" => "sk-test")

      assert_equal :undeclared, result.outcomes.fetch("openai_api")
      assert_empty ModelProviderCredential.where(
        account_id: @account.id, provider_id: "openai_api"
      )
    end
  end

  # THE NEGATIVE THE GUARD EXISTS FOR: CI runs `db:seed:replant` in the test
  # env, and a test database has every reason not to hold a real key.
  test "test seeds import no credentials or cost unit" do
    before = ModelProviderCredential.count

    seed("test", @env.transform_values { "fake-test-material" })

    assert_equal before, ModelProviderCredential.count
    assert_nil @account.reload.cost_unit
  end

  private

    def import(overrides = {})
      ModelProviders::ImportEnvironmentCredentials.call(
        account: @account, env: @env.merge(overrides)
      )
    end

    def seed(environment, overrides = {})
      saved = @env.keys.index_with { ENV[_1] }
      @env.merge(overrides).each { |key, value| ENV[key] = value }
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new(environment)) do
        load Rails.root.join("db/seeds.rb")
      end
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
end
