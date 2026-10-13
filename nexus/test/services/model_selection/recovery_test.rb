require "test_helper"

class ModelSelection::RecoveryTest < ActiveSupport::TestCase
  Port = Data.define(:results, :calls) do
    def resolve(account:, workload:, submitted:, configuration:)
      calls << submitted.model
      results.fetch(submitted.model)
    end
  end

  setup do
    @account = accounts(:cybros)
  end

  test "unavailable candidates are skipped once in configured order" do
    port = port_for("a/primary" => :provider_disabled, "b/first" => :missing_credential,
      "c/answer" => nil, "d/later" => nil)
    result = recover(port, fallbacks: %w[b/first b/first a/primary c/answer d/later])

    assert_equal "c/answer", result.selection
    assert_equal %w[a/primary b/first c/answer], port.calls
    assert_equal [{ "model" => "a/primary", "reason" => "provider_disabled" },
      { "model" => "b/first", "reason" => "missing_credential" }], result.skips
  end

  test "a disabled automatic policy and deterministic primary refusal do not try fallbacks" do
    port = port_for("a/primary" => :provider_disabled, "b/first" => nil)
    assert_not recover(port, fallbacks: []).resolved?
    assert_equal ["a/primary"], port.calls

    port = port_for("a/primary" => :invalid_generation_configuration, "b/first" => nil)
    assert_equal :invalid_generation_configuration, recover(port, fallbacks: ["b/first"]).refusal
    assert_equal ["a/primary"], port.calls
  end

  test "a retry resumes after its current route and does not revisit a skipped earlier candidate" do
    port = port_for("a/primary" => nil, "b/first" => nil, "c/current" => nil, "d/last" => nil)
    result = recover(port, current: "c/current", include_current: false,
      fallbacks: %w[b/first c/current d/last], excluded: ["a/primary"])

    assert_equal "d/last", result.selection
    assert_equal ["d/last"], port.calls
  end

  test "provider constraints permit other configured models on that provider only" do
    port = port_for("a/primary" => :provider_disabled, "b/same-family" => nil, "a/other" => nil)
    result = recover(port, constraint: "provider", fallbacks: %w[b/same-family a/other])

    assert_equal "a/other", result.selection
    assert_equal %w[a/primary a/other], port.calls
    assert_equal "provider_constraint", result.skips[1].fetch("reason")
  end

  test "an explicit route stays explicit even when it equals the configured default" do
    port = port_for("a/primary" => :model_hidden, "b/fallback" => nil)
    result = recover(port, source: "explicit", constraint: "route", fallbacks: ["b/fallback"])

    assert_not result.resolved?
    assert_equal ["a/primary"], port.calls
    assert_equal "provider_constraint", result.skips.last.fetch("reason")
  end

  test "an individually authorized alternative may cross both constraints" do
    port = port_for("a/primary" => :model_hidden, "b/fallback" => nil)
    result = recover(port, source: "explicit", constraint: "route", fallbacks: ["b/fallback"],
      alternatives: ["b/fallback"])

    assert_equal "b/fallback", result.selection
    assert_equal %w[a/primary b/fallback], port.calls
  end

  test "model equality requires matching explicit exact version metadata" do
    catalog = Struct.new(:models).new({
      "a/primary" => { "model_identity" => "vendor/model@2026-10-01" },
      "b/alias" => { "model_identity" => "vendor/model@2026-10-01" },
      "b/same-family" => { "model_identity" => "vendor/model@2026-10-02" },
      "c/primary" => {},
    })
    port = port_for("a/primary" => :model_hidden, "b/alias" => nil)
    ModelSelection::Resolver.stub(:effective_catalog, catalog) do
      result = recover(port, source: "explicit", constraint: "model",
        fallbacks: %w[b/same-family c/primary b/alias])
      assert_equal "b/alias", result.selection
      assert_equal %w[a/primary b/alias], port.calls
      assert_equal %w[model_hidden model_constraint model_constraint], result.skips.map { |skip| skip.fetch("reason") }
    end
  end

  test "a resolved fallback must pass the caller's assembled request gate before advancing" do
    port = port_for("a/primary" => :provider_disabled, "b/too-small" => nil, "c/compatible" => nil)
    result = recover(port, fallbacks: %w[b/too-small c/compatible]) do |selection|
      :input_too_large if selection == "b/too-small"
    end

    assert_equal "c/compatible", result.selection
    assert_equal "input_too_large", result.skips.last.fetch("reason")
  end

  test "a fallback without function tools is skipped before a tool-bearing request runs" do
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    no_tools = selection.with(execution_profile: selection.execution_profile.with(
      capabilities: selection.execution_profile.capabilities - ["tool_calls"]))
    port = Port.new(results: {
      "a/primary" => ModelSelection::Result.refused(:provider_disabled),
      "b/no-tools" => ModelSelection::Result.resolved(no_tools),
      "c/capable" => ModelSelection::Result.resolved(selection),
    }, calls: [])
    tools = [{ "type" => "function", "function" => { "name" => "read_file" } }]

    result = recover(port, fallbacks: %w[b/no-tools c/capable]) do |candidate|
      ModelSelection::Recovery.tools_refusal(candidate, tools)
    end

    assert_equal selection, result.selection
    assert_equal %w[a/primary b/no-tools c/capable], port.calls
    assert_equal "model_capability_unavailable", result.skips.last.fetch("reason")
  end

  test "an exact context overflow skips a fallback while an estimate cannot reject it" do
    selection = DevModelLane.selection(workload: "text_generation", account: @account)
    profile = selection.execution_profile.with(token_counter: { kind: "tiktoken", encoding: "cl100k_base" })
    candidate = selection.with(execution_profile: profile)
    limit = candidate.capabilities.limits.planning_input_bound
    assert_not_nil limit
    input = "the accepted request"

    exact = ModelRequests::TokenCount::Result.counted(limit + 1, exact: true)
    ModelRequests::TokenCount.stub(:count, exact) do
      assert_equal :estimated_input_exceeds_model_limit, ModelSelection::Recovery.context_refusal(candidate, input)
    end
    estimate = ModelRequests::TokenCount::Result.counted(limit + 1, exact: false)
    ModelRequests::TokenCount.stub(:count, estimate) do
      assert_nil ModelSelection::Recovery.context_refusal(candidate, input)
    end
  end

  private

    def port_for(results)
      Port.new(results: results.to_h { |reference, reason|
        [reference, reason ? ModelSelection::Result.refused(reason) : ModelSelection::Result.resolved(reference)]
      }, calls: [])
    end

    def recover(port, fallbacks:, current: "a/primary", source: "default", constraint: "any",
                alternatives: [], excluded: [], include_current: true, &accept_candidate)
      ModelSelection::Recovery.resolve(account: @account, workload: "text_generation", port: port,
        submitted: Nexus::SubmittedModelSelection.new(model: current, reasoning_effort: nil),
        model_selection: ModelSelectionIntent.new(source: source, model: "a/primary", constraint: constraint,
          alternatives: alternatives), fallback_models: fallbacks, configuration: {}, excluded: excluded,
        include_current: include_current, &accept_candidate)
    end
end
