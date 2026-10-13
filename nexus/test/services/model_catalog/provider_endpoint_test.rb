require "test_helper"

# WHERE each provider is reached.
#
# The endpoint is the one implementation fact that lives in the catalog
# rather than the registry, because the E2E harness has to point the dev
# provider at a loopback port it allocates at run time — a checked-in
# constant cannot carry a port that does not exist yet. Everything about HOW
# to talk stays in the registry, and the compiler's closed key set is what
# keeps that split from eroding.
class ModelCatalog::ProviderEndpointTest < ActiveSupport::TestCase
  # Composed with each profile's own relative wire path, these are the real
  # provider routes. Origin plus any prefix the provider's own routing fixes
  # (`openrouter.ai/api`, `chatgpt.com/backend-api/codex`) — never `/v1`,
  # which the profile side owns.
  EXPECTED = {
    "openai_api" => "https://api.openai.com",
    "anthropic" => "https://api.anthropic.com",
    "gemini" => "https://generativelanguage.googleapis.com",
    "codex_subscription" => "https://chatgpt.com/backend-api/codex",
    "openrouter" => "https://openrouter.ai/api",
    "deepseek" => "https://api.deepseek.com",
    "xai" => "https://api.x.ai",
  }.freeze

  test "every shipped provider declares its endpoint" do
    candidate = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"))

    assert_equal EXPECTED.keys.sort, candidate.providers.keys.sort
    EXPECTED.each do |provider_id, base_url|
      assert_equal base_url, candidate.providers.fetch(provider_id).fetch("base_url")
    end
  end

  test "the facade answers from the published snapshot and refuses an unknown provider" do
    assert_equal "http://127.0.0.1:3000/mock_llm", ModelCatalog.provider_base_url("dev")

    assert_raises(ModelCatalog::Unavailable) { ModelCatalog.provider_base_url("nobody") }
  end

  # The value is deploy-time, not request-time: the accept-time selection
  # exposes the stable provider key but no endpoint, so queued work resolves
  # the current endpoint only when it is sent.
  test "the endpoint is absent from an accept-time selection" do
    DevModelLane.ensure_enabled!(accounts(:cybros))
    selection = DevModelLane.selection(workload: "text_generation", account: accounts(:cybros))

    assert_equal "dev", selection.provider_id
    assert_not_respond_to selection, :base_url
    assert_not_respond_to selection.execution_profile, :base_url
  end
end
