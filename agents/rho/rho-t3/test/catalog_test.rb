require_relative "test_helper"

class CatalogTest < Minitest::Test
  include T3Test

  def test_discovery_lists_human_names_supported_models_and_readiness_without_native_identifiers
    providers = provider_catalog
    providers.last.merge!("status" => "warning", "auth" => { "status" => "unauthenticated" })
    catalog = Rho::T3::Catalog.new(providers: providers)
    report = catalog.report

    assert_equal ["Codex", "Claude Code"], report.map { |agent| agent.fetch("agent") }
    assert report.first.fetch("available"), "an unknown auth status can still be a ready native provider"
    refute report.last.fetch("available")
    assert_equal "fixture-code", report.first.fetch("models").first.fetch("id")
    assert_equal "fixture-code", report.first.fetch("default_model")
    refute_includes JSON.generate(report), "instanceId"
    refute_includes JSON.generate(report), "native-codex"
  end

  def test_harness_and_model_names_resolve_only_inside_the_selected_native_catalog
    catalog = Rho::T3::Catalog.new(providers: provider_catalog)
    selected = catalog.select(agent: "claude code", model: "Review")

    assert_equal({ "instanceId" => "native-claude", "model" => "fixture-review" }, selected.native)
    assert_equal "Claude Code", selected.agent
    assert_equal selected, catalog.select(agent: "Claude", model: "fixture-review")
    assert_raises(Rho::T3::Error) { catalog.select(agent: "Codex", model: "fixture-review") }
    assert_raises(Rho::T3::Error) { catalog.select(agent: "Missing Agent", model: "fixture-code") }
    assert_raises(Rho::T3::Error) { catalog.select(agent: "Codex", model: "nexus:other-provider-model") }
  end

  def test_defaults_do_not_silently_choose_an_agent_or_replace_an_explicit_unavailable_choice
    providers = provider_catalog
    catalog = Rho::T3::Catalog.new(providers: providers)
    assert_raises(Rho::T3::Error) { catalog.select }
    assert_equal "fixture-code", catalog.select(agent: "Codex").model

    providers.first["enabled"] = false
    unavailable = Rho::T3::Catalog.new(providers: providers)
    assert_raises(Rho::T3::Error) { unavailable.select(agent: "Codex") }
    assert_equal "Claude Code", unavailable.select.agent
  end

  def test_multiple_instances_require_a_distinct_human_name
    providers = provider_catalog
    providers.first["displayName"] = "Personal Codex"
    providers << providers.first.merge("instanceId" => "native-work", "displayName" => "Work Codex")
    catalog = Rho::T3::Catalog.new(providers: providers)

    assert_raises(Rho::T3::Error) { catalog.select(agent: "Codex") }
    assert_equal "native-work", catalog.select(agent: "Work Codex").instance_id
  end

  def test_missing_native_default_uses_its_first_standard_model_without_static_fallbacks
    providers = provider_catalog
    providers.first.fetch("models").first.delete("isDefault")
    providers.first.fetch("models").unshift({ "slug" => "custom", "name" => "Custom", "isDefault" => true, "isCustom" => true })
    catalog = Rho::T3::Catalog.new(providers: providers)

    assert_equal "fixture-code", catalog.select(agent: "Codex").model
    assert_equal "fixture-code", catalog.select(agent: "Codex", model: "Code Model").model
    providers.first["models"] = []
    assert_raises(Rho::T3::Error) { Rho::T3::Catalog.new(providers: providers).select(agent: "Codex") }
  end
end
