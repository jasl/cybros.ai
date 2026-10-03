require "test_helper"
require_relative "../support/ops_harness"

class OpsModelsTest < Minitest::Test
  include RhoTest::OpsHarness

  MODEL = {
    "ref" => "dev/mock-text", "provider" => "dev", "workload" => "text_generation",
    "visible" => true, "available" => true, "unavailable_reason" => nil, "capabilities" => { "tool_calls" => true },
    "pricing" => { "state" => "priced", "unit" => "USD", "input_per_mtok" => "1.00", "output_per_mtok" => "2.00" },
  }.freeze

  def test_models_requires_the_daemon_bearer_and_a_connected_member_plane
    daemon = boot
    assert_equal "401", request(daemon, :get, "/models").code
    response = request(daemon, :get, "/models", token: bearer(daemon))
    assert_equal "409", response.code
    assert_equal "member_plane_unavailable", JSON.parse(response.body).dig("error", "code")
  end

  def test_models_forwards_the_workload_and_preserves_the_available_catalog_projection
    api = NexusDoubles::FakeAgentApi.new(models: [MODEL])
    daemon = member_ready(boot, api)

    ["workload=text_generation", "workload=text_generation&available=false"].each do |query|
      response = request(daemon, :get, "/models?#{query}", token: bearer(daemon))
      assert_equal "200", response.code, response.body
      assert_equal [MODEL], JSON.parse(response.body).fetch("models")
      path, credential, params = api.requests.find_all { |entry| entry.first == "/agent_api/v1/models" }.last
      assert_equal "/agent_api/v1/models", path
      assert_equal NexusDoubles::MEMBER_TOKEN, credential
      assert_equal({ "workload" => "text_generation" }, params)
    end
  end

  class CommandsTest < Minitest::Test
    include RhoTest::CliHarness

    def test_models_prints_available_models_or_json
      rows = [MODEL]
      announce(endpoint: routed_endpoint("GET /models" => [[200, { "models" => rows }]]))
      assert_equal rows, Rho::Extensions::Ops::Models.command(cli, [], {})
      assert_equal "dev/mock-text  text_generation\n", @out.string
      @out.truncate(0)
      @out.rewind
      Rho::Extensions::Ops::Models.command(cli, [], { json: true })
      assert_equal({ "models" => rows }, JSON.parse(@out.string))
    end

    def test_models_prints_an_empty_listing_and_relays_daemon_refusals
      announce(endpoint: routed_endpoint("GET /models" => [[200, { "models" => [] }],
        [503, { "error" => { "code" => "kernel_unavailable", "message" => "no member plane" } }]]))
      assert_empty Rho::Extensions::Ops::Models.command(cli, [], {})
      assert_equal "(no models)\n", @out.string
      error = assert_raises(Rho::Core::Refused) { Rho::Extensions::Ops::Models.command(cli, [], {}) }
      assert_equal "no member plane", error.message
    end

    def test_the_core_preserves_the_workload_filter
      seen = []
      announce(endpoint: recording_routed_endpoint(seen, "GET /models" => [[200, { "models" => [] }]]))
      core.models
      core.models(workload: "text_generation")
      assert_equal ["/models", "/models?workload=text_generation"],
        seen.grep(%r{\AGET /models}).map { |request| request.lines.first.split[1] }
    end
  end
end
