require "test_helper"

# Every Agent discovers the account's available models through the member
# endpoint. Availability and configuration are decided by the server.
class ApiModelCatalogTest < Minitest::Test
  ROW = {
    "ref" => "dev/acme/text",
    "provider" => "dev",
    "workload" => "text_generation",
    "visible" => true,
    "available" => true,
    "unavailable_reason" => nil,
    "capabilities" => { "tool_calls" => true, "streaming" => true },
    "pricing" => { "state" => "priced", "unit" => "USD",
                   "input_per_mtok" => "0.3", "output_per_mtok" => "1.2" },
  }.freeze

  def catalog(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
      transport: @transport).models
  end

  def request = @transport.requests.fetch(0)

  def test_a_listed_model_carries_the_lane_the_price_and_whether_it_runs
    model = catalog([[200, {}, { "models" => [ROW] }]]).list.fetch(0)

    assert_equal :get, request.fetch(:method)
    assert_equal "/agent_api/v1/models", request.fetch(:path)
    assert_equal "dev/acme/text", model.ref
    assert_predicate model, :available?
    assert_predicate model, :visible?
    assert_predicate model, :tool_calls?
    assert_predicate model.pricing, :priced?
    assert_equal "USD", model.pricing.unit
  end

  # A model with no capability block is not a model that can do
  # everything: the predicate a tool-driven run asks must answer false.
  def test_capabilities_absent_is_not_capabilities_granted
    row = ROW.reject { |key, _| key == "capabilities" }
    model = catalog([[200, {}, { "models" => [row] }]]).list.fetch(0)

    refute_predicate model, :tool_calls?
  end

  def test_workload_narrows_the_member_listing_without_an_availability_selector
    catalog([[200, {}, { "models" => [ROW] }]]).list(workload: "text_generation")

    assert_equal({ "workload" => "text_generation" }, request.fetch(:params))
  end

  def test_an_unpriced_lane_states_no_rate_rather_than_a_zero
    row = ROW.merge("pricing" => { "state" => "unmetered" })
    model = catalog([[200, {}, { "models" => [row] }]]).list.fetch(0)

    refute_predicate model.pricing, :priced?
    assert_nil model.pricing.input_per_mtok
  end
end
