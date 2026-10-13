require "test_helper"

class AgentRuns::Models::ListTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
  end

  test "the kernel job lists the account's available metadata without private provider facts" do
    @account.update!(cost_unit: "USD")
    node = calls({ "limit" => 100 }).sole
    AgentRuns::ToolDiscoveryJob.perform_now(node.id)
    result = output(node)
    catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
    expected = AgentAPI::ModelPresenter.index(account: @account, catalog: catalog)
      .select { |model| model.fetch(:available) }
      .map { |model| model.slice(:ref, :provider, :model_identity, :capabilities, :pricing).deep_stringify_keys }

    assert_equal expected, result.fetch("models")
    assert_equal expected.length, result.fetch("total")
    assert_equal 0, result.fetch("offset")
    assert_nil result.fetch("next_offset")
    assert_equal ModelCatalog.current.models.keys.grep(/\Adev\//).sort,
      result.fetch("models").map { |model| model.fetch("ref") }
    priced = result.fetch("models").find { |model| model.fetch("ref") == DevModelLane::PRICED_TEXT_MODEL }
    assert_equal "priced", priced.dig("pricing", "state")
    assert_equal true, priced.dig("capabilities", "tool_calls")
    assert result.fetch("models").all? { |model| model.keys.sort == %w[capabilities model_identity pricing provider ref] }
    assert_not node.reload.output_summary["is_error"]
    assert_equal :not_running, AgentRuns::Models::List.call(node: node)
  end

  test "live hidden unavailable disabled and missing-credential models stay out of discovery" do
    node = calls({ "limit" => 100 }).sole
    @policy.update!(model_overrides: ModelProviderConfig.empty_overrides.merge(
      "hidden_models" => ["dev/mock-text"],
      "unavailable_models" => [DevModelLane::PRICED_TEXT_MODEL]
    ))
    @account.model_provider_configs.create!(provider_id: "test_api", enabled: true,
      model_overrides: ModelProviderConfig.empty_overrides)
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "test_api")
    assert_equal :applied, AgentRuns::Models::List.call(node: node)
    refs = output(node).fetch("models").map { |model| model.fetch("ref") }
    assert_equal ModelCatalog.current.models.keys.grep(/\Adev\//).sort -
      ["dev/mock-text", DevModelLane::PRICED_TEXT_MODEL], refs

    @policy.update!(model_overrides: ModelProviderConfig.empty_overrides)
    node = calls({}).sole
    @policy.update!(enabled: false)
    assert_equal :applied, AgentRuns::Models::List.call(node: node)
    assert_equal({ "models" => [], "total" => 0, "offset" => 0, "next_offset" => nil }, output(node))
  end

  test "query matches refs providers upstream model names and exact identities without regard to case" do
    upsert_models("dev/catalog-alias" => { "model_id" => "Upstream-Choice",
      "model_identity" => "vendor/Exact-Version@2026-10-01" })
    calls({ "query" => "CATALOG-ALIAS" }, { "query" => "upSTREAM" },
      { "query" => "exact-VERSION" }, { "query" => "DeV", "limit" => 100 },
      { "query" => "no-match" }).each_with_index do |node, index|
      assert_equal :applied, AgentRuns::Models::List.call(node: node)
      result = output(node)
      refs = result.fetch("models").map { |model| model.fetch("ref") }
      if index < 3
        assert_equal ["dev/catalog-alias"], refs
        assert_equal "vendor/Exact-Version@2026-10-01", result.fetch("models").sole.fetch("model_identity")
      elsif index == 3
        assert_equal (ModelCatalog.current.models.keys.grep(/\Adev\//) + ["dev/catalog-alias"]).sort, refs
      else
        assert_equal [], refs
        assert_equal 0, result.fetch("total")
      end
      assert_nil result.fetch("next_offset")
    end
  end

  test "default and explicit pages preserve stable ordering and terminate beyond the last match" do
    upsert_models((0...25).to_h { |index| [format("dev/page-%02d", index), {}] })
    nodes = calls({ "query" => "dev/page-" }, { "query" => "dev/page-", "offset" => 20 },
      { "query" => "dev/page-", "offset" => 3, "limit" => 2 },
      { "query" => "dev/page-", "offset" => 2**128 })
    nodes.each { |node| assert_equal :applied, AgentRuns::Models::List.call(node: node) }
    first, last, small, beyond = nodes.map { |node| output(node) }
    assert_equal (0...20).map { |index| format("dev/page-%02d", index) }, first.fetch("models").map { |row| row.fetch("ref") }
    assert_equal [25, 0, 20], first.values_at("total", "offset", "next_offset")
    assert_equal (20...25).map { |index| format("dev/page-%02d", index) }, last.fetch("models").map { |row| row.fetch("ref") }
    assert_equal [25, 20, nil], last.values_at("total", "offset", "next_offset")
    assert_equal %w[dev/page-03 dev/page-04], small.fetch("models").map { |row| row.fetch("ref") }
    assert_equal [25, 3, 5], small.values_at("total", "offset", "next_offset")
    assert_equal({ "models" => [], "total" => 25, "offset" => 2**128, "next_offset" => nil }, beyond)
  end

  test "invalid query and pagination settle as correctable tool errors" do
    invalid = [{ "query" => [] }, { "query" => nil }, { "limit" => 0 }, { "limit" => 101 },
      { "limit" => "20" }, { "offset" => -1 }, { "offset" => 0.5 }, { "offset" => "0" }, { "unknown" => true }]
    calls(*invalid).each do |node|
      assert_equal :applied, AgentRuns::Models::List.call(node: node)
      assert_match(/parameter_invalid/, node.reload.output_body.effective_text)
      assert node.output_summary.fetch("is_error")
    end
  end

  private

    def calls(*inputs)
      run = seed(model("round1", "kernel_tools" => ["nexus.models.list"]), default_runner_executor_public_id: nil)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: run, acting_user: @human)), :accepted?
      schedule_loop!(run)
      run_loop_round!(run, sse_success("list models", tool_calls: inputs.each_with_index.map { |input, index|
        { id: "list-#{index}", name: "models_list", arguments: input.to_json }
      }))
      inputs.each_index.map { |index| loop_node(run, "r1t#{index}") }
    end

    def output(node) = JSON.parse(node.reload.output_body.effective_text)

    def upsert_models(models)
      @policy.update!(model_overrides: ModelProviderConfig.empty_overrides.merge(
        "entries" => models.transform_values { |definition| { "op" => "upsert", "model" => definition } }
      ))
    end
end
