require "test_helper"

# THE HOLE THIS CLOSES: `--model openrouter/…` demanded that a person
# already know the exact catalog ref, and nothing published one. The
# catalog is a constant of the server process; the only way to read it was
# to open the YAML on the host. A console cannot offer a choice it cannot
# see, and a person at a terminal was guessing.
class AgentAPI::V1::ModelsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @token = create_access_token_fixture(user: @human, name: "Member")
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  def listing(query = nil)
    get ["/agent_api/v1/models", query].compact.join("?"), headers: auth
    assert_response :success
    response.parsed_body.fetch("models")
  end

  test "all available models are listed for a human and agents of any steward" do
    expected = ModelCatalog.current.models.keys.select { |ref| ref.start_with?("dev/") }.sort
    assert_equal expected, listing.map { |model| model.fetch("ref") }

    [users(:owner), users(:member)].each do |steward|
      pair = connect_agent_session(steward: steward, agent_identifier: "models-#{steward.handle}")
      get "/agent_api/v1/models", headers: { "Authorization" => "Bearer #{pair.access_secret}" }
      assert_response :success
      assert_equal expected, response.parsed_body.fetch("models").map { |model| model.fetch("ref") }
    end
  end

  test "unavailable models are omitted even when available is explicitly false" do
    %w[available=true available=false].each do |query|
      models = listing(query)
      assert models.all? { |model| model.fetch("available") && model.fetch("visible") }
      assert models.all? { |model| model.fetch("unavailable_reason").nil? }
      refute models.any? { |model| model.fetch("provider") != "dev" }
    end

    ModelProviders::DisableLane.call(
      account: @account, provider_id: "dev",
      expected_lock_version: ModelProviderPolicy.find_by(account: @account, provider_id: "dev").lock_version
    )
    assert_empty listing("available=false")
  end

  # WHAT A CODING AGENT ACTUALLY NEEDS TO KNOW. A model that cannot make a
  # tool call cannot drive a loop with tools: choosing it is a wasted
  # round, and the capability is declared per model.
  test "capabilities carry the one a tool-driven loop depends on" do
    dev = listing.find { |model| model.fetch("ref") == "dev/mock-text" }
    capabilities = dev.fetch("capabilities")

    assert_includes capabilities.keys, "tool_calls"
    assert_equal DevModelLane.profile_for("dev/mock-text").capability_enabled?("tool_calls"),
      capabilities.fetch("tool_calls")
    assert_equal ["text"], capabilities.fetch("output_modalities")
    assert_equal true, capabilities.fetch("tool_calls"), "a silent dev row has its wire's tools"
    refute_includes capabilities.keys, "parallel_tool_calls",
      "no row states a parallel fact, so the projection carries none (owner 2026-09-16)"
  end

  # Money is the catalog's own number, projected the way settlement reads
  # it — including the state, because "unmetered" and "free" are different
  # claims and a chooser deserves the difference.
  test "pricing is the effective projection, not a second table" do
    @account.update!(cost_unit: "USD")
    priced = listing.find { |model| model.fetch("ref") == DevModelLane::PRICED_TEXT_MODEL }
    assert_equal "priced", priced.dig("pricing", "state")
    assert_equal @account.cost_unit, priced.dig("pricing", "unit")
    assert_match(/\A\d/, priced.dig("pricing", "input_per_mtok"))

    unmetered = listing.find { |model| model.fetch("ref") == DevModelLane::UNMETERED_TEXT_MODEL }
    assert_equal "unmetered", unmetered.dig("pricing", "state")
    refute unmetered.fetch("pricing").key?("input_per_mtok"),
      "a lane nobody priced states no rate rather than a zero"
  end

  # An account that has not chosen a unit cannot be quoted a price, and
  # that is a state a console must render rather than a blank cell.
  test "an account with no cost unit is told the cost is unknown" do
    assert_nil @account.cost_unit
    priced = listing.find { |model| model.fetch("ref") == DevModelLane::PRICED_TEXT_MODEL }

    assert_equal "cost_unknown", priced.dig("pricing", "state")
    refute priced.fetch("pricing").key?("input_per_mtok")
  end

  test "the listing narrows to a workload and to what will actually run" do
    every = listing
    text = listing("workload=text_generation")
    assert_operator text.length, :<, every.length
    assert(text.all? { |model| model.fetch("workload") == "text_generation" })

    runnable = listing("available=true")
    assert(runnable.all? { |model| model.fetch("available") })
    assert(runnable.any? { |model| model.fetch("ref") == "dev/mock-text" })
  end

  test "the member plane is the only one that reads it" do
    get "/agent_api/v1/models"
    assert_response :unauthorized
  end

  # A server whose catalog never booted has no models, and saying so is the
  # honest answer: one 503 for the whole plane, never an empty list.
  test "a catalog that is not available is 503 model_plane_unavailable" do
    ModelCatalog.stub(:current, -> { raise ModelCatalog::Unavailable }) do
      get "/agent_api/v1/models", headers: auth
    end
    assert_response :service_unavailable
    assert_equal "model_plane_unavailable", response.parsed_body.dig("error", "code")
  end
end
