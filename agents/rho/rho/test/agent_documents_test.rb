require "test_helper"

class AgentDocumentsTest < Minitest::Test
  def test_markdown_and_json_round_trip_configuration_without_identity_or_role_publication
    configuration = Rho::AgentPresets::DEFAULT_CONFIGURATION.merge(
      "model" => "test/text", "system_prompt" => "Inspect carefully.\nKeep evidence.",
      "tools" => %w[read spawn], "runner_tool_names" => nil, "fallback_models" => [],
      "prompt_template" => { "version" => 1, "blocks" => [] })
    preset = Rho::AgentPresets::Entry.new(public_id: "old-preset", name: "Code Reviewer", description: "Reviews changes",
      configuration: configuration, role: Rho::AgentPresets::Role.new(name: "reviewer", description: "Published role only"))

    %w[md json].each do |format|
      text = Rho::AgentPresets::Portable.dump(preset, format: format)
      parsed = Rho::AgentPresets::Portable.load(text, format: format)
      assert_equal "Code Reviewer", parsed.fetch(:name)
      assert_equal preset.description, parsed.fetch(:description)
      assert_equal configuration, parsed.fetch(:configuration)
      %w[old-preset public_id audience memory home_workspace_public_id].each { |field| refute_includes text, "\"#{field}\":" }
      refute_includes text, "old-preset"
      refute_includes text, "Published role only"
    end
  end

  def test_flat_json_and_markdown_use_the_same_configuration_fields
    json = JSON.generate("name" => "Reviewer", "description" => "Reviews changes", "tools" => ["read"],
      "model" => "test/text", "fallback_models" => [], "system_prompt" => "Be precise.")
    markdown = "---\nname: Reviewer\ndescription: Reviews changes\ntools: [read]\nmodel: test/text\nfallback_models: []\n---\nBe precise."
    parsed = Rho::AgentPresets::Portable.load(json, format: "json")
    assert_equal parsed, Rho::AgentPresets::Portable.load(markdown, format: "md")
    assert_equal "Reviewer", parsed.fetch(:name)
    assert_equal({ "tools" => ["read"], "model" => "test/text", "fallback_models" => [], "system_prompt" => "Be precise." },
      parsed.fetch(:configuration))
  end

  def test_malformed_documents_and_identity_fields_are_refused_before_import
    ["{", "[]", JSON.generate("name" => "reviewer", "description" => "Reviews", "audience" => "external")].each do |text|
      assert_raises(Rho::AgentPresets::Error) { Rho::AgentPresets::Portable.load(text, format: "json") }
    end
  end

  def test_an_unnamed_document_uses_its_filename_as_the_preset_display_name
    parsed = Rho::AgentPresets::Portable.load(JSON.generate("description" => "Checks changes", "model" => "test/text"),
      format: "json", filename: "Code Reviewer.json")
    assert_equal "Code Reviewer", parsed.fetch(:name)
  end

  def test_malformed_json_does_not_echo_document_contents
    error = assert_raises(Rho::AgentPresets::Error) do
      Rho::AgentPresets::Portable.load('{"system_prompt":"private draft",', format: "json")
    end

    assert_equal "Invalid JSON Preset document", error.message
    refute_includes error.message, "private draft"
  end
end
