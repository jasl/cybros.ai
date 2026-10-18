require "test_helper"
require_relative "support/environment_fixtures"

class AgentPresetDocumentsTest < Minitest::Test
  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    @catalog = Rho::AgentPresets.new(store: -> { @store })
    @catalog.list
  end

  def test_preset_names_are_display_names_and_role_names_use_the_handle_grammar
    named = import(markdown(name: "Code Reviewer"), filename: "unrelated.md")
    unnamed = import(markdown, filename: "Code Reviewer.md")
    padded = import(markdown(name: "\"  Padded Name  \""))

    assert_equal ["Code Reviewer", "Code Reviewer", "Padded Name"], [named.name, unnamed.name, padded.name]
    assert_equal "custom-reviewer", @catalog.publish(named.public_id, name: " Custom-Reviewer ", description: "Reviews changes").role.name
    ["x", "a b", "reviewer!", "a" * 33].each do |name|
      assert_raises(Rho::AgentPresets::Error) { @catalog.publish(named.public_id, name: name, description: "Reviews changes") }
    end
    assert_equal "custom-reviewer", @catalog.fetch(named.public_id).role.name
  end

  def test_missing_blank_long_and_non_string_metadata_never_write_a_preset
    before = @store.calls.length
    invalid = [
      "---\nname: Missing\n---\nBody\n",
      markdown(description: '"   "'),
      markdown(description: "x" * 1025),
      markdown(description: "[a, b]"),
      markdown(name: "[a, b]"),
      markdown(name: '"   "'),
    ]
    invalid.each { |text| assert_raises(Rho::AgentPresets::Error) { import(text) } }

    assert_equal before, @store.calls.length
  end

  def test_role_description_is_one_bounded_line
    entry = import(markdown)
    role = @catalog.publish(entry.public_id, name: "custom-reviewer", description: "Reviews a diff\nfor defects;\t reports\n\nwhat matters.").role
    assert_equal "Reviews a diff for defects; reports what matters.", role.description
    [nil, "", "x" * 1025, ["a", "b"]].each do |description|
      assert_raises(Rho::AgentPresets::Error) { @catalog.publish(entry.public_id, name: "custom-reviewer", description: description) }
    end
    assert_equal role, @catalog.fetch(entry.public_id).role
  end

  def test_tools_models_and_prompt_whitespace_are_preserved_at_their_own_boundary
    prompt = "\n  You review 中文.  \n\n"
    listed = import(markdown(extra: "tools:\n  - read\n  - grep\nmodel: test/text\n", body: prompt))
    inherited = import(markdown(extra: "tools: read, nope ,spawn\nmodel: inherit\n", body: ""))
    empty = import(markdown(extra: "tools: []\nrunner_tool_names: []\nfallback_models: []\n"))
    absent = import(markdown)

    assert_equal %w[read grep], listed.configuration.fetch("tools")
    assert_equal "test/text", listed.configuration.fetch("model")
    assert_equal prompt, listed.configuration.fetch("system_prompt")
    assert_equal %w[read nope spawn], inherited.configuration.fetch("tools")
    assert_equal "follow", inherited.configuration.fetch("model_mode")
    assert_nil inherited.configuration.fetch("model")
    assert_nil inherited.configuration.fetch("system_prompt")
    %w[tools runner_tool_names fallback_models].each do |key|
      assert_equal [], empty.configuration.fetch(key)
      assert_nil absent.configuration.fetch(key)
    end
  end

  def test_unknown_and_retired_fields_are_refused_instead_of_becoming_another_authority
    %w[fallback_model color permissionMode maxTurns audience display_name].each do |field|
      error = assert_raises(Rho::AgentPresets::Error) { import(markdown(extra: "#{field}: unwanted\n")) }
      assert_includes error.message, field
    end
    assert_equal 6, @catalog.list.length
  end

  def test_configuration_types_are_validated_before_a_document_is_written
    ["tools: {a: b}\n", "tools: [read, 3]\n", "model: [a]\n", "model: alias\n",
     "prompt_template: invalid\n", "runner_tool_names: false\n", "fallback_models: test/text\n"].each do |extra|
      assert_raises(Rho::AgentPresets::Error) { import(markdown(extra: extra)) }
    end
    [nil, false, [], "invalid"].each do |configuration|
      text = JSON.generate("name" => "Invalid", "description" => "Rejected", "configuration" => configuration)
      assert_raises(Rho::AgentPresets::Error) { import(text, format: "json") }
    end
    assert_equal 6, @catalog.list.length
  end

  def test_malformed_frontmatter_json_and_unsupported_formats_report_a_refusal
    [
      ["md", "# No frontmatter\n", "no frontmatter block"],
      ["md", "---\n- a\n---\nBody\n", "frontmatter is not a mapping"],
      ["md", "---\ndescription: a: b: c\n---\nBody\n", "frontmatter did not parse"],
      ["json", "{", "Invalid JSON Preset document"],
      ["json", "[]", "Preset document must be an object"],
      ["txt", "A document", "format must be md or json"],
    ].each do |format, text, reason|
      error = assert_raises(Rho::AgentPresets::Error) { import(text, format: format) }
      assert_includes error.message, reason
    end
    assert_equal 6, @catalog.list.length
  end

  def test_prompt_templates_and_utf8_text_round_trip_through_the_catalog
    entry = import(markdown(extra: "prompt_template:\n  blocks:\n    - type: history\n    - type: input\n",
      body: "  审查内容。\n\n    保留缩进。\n"))
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }] }
    assert_equal template, entry.configuration.fetch("prompt_template")
    %w[md json].each do |format|
      text = Rho::AgentPresets::Portable.dump(entry, format: format)
      copy = import(text, format: format)
      refute_equal entry.public_id, copy.public_id
      assert_equal entry.configuration, copy.configuration
      assert_nil copy.role
    end
  end

  def test_mcp_references_round_trip_without_copying_connection_configuration
    selection = { "disabled_connections" => [], "disabled_tools" => [{ "source" => "nexus", "connection_public_id" => SecureRandom.uuid_v7, "tool_name" => "search" }] }
    entry = import(JSON.generate("name" => "Work account", "description" => "Disabled tool", "mcp" => selection), format: "json")

    %w[md json].each do |format|
      copy = import(Rho::AgentPresets::Portable.dump(entry, format: format), format: format)
      assert_equal selection, copy.configuration.fetch("mcp")
      refute_equal entry.public_id, copy.public_id
    end
    assert_equal Rho::AgentPresets::DEFAULT_CONFIGURATION.fetch("mcp"), import(markdown).configuration.fetch("mcp")
  end

  private

    def import(text, format: "md", filename: "preset.md")
      @catalog.create(**Rho::AgentPresets::Portable.load(text, format: format, filename: filename))
    end

    def markdown(name: nil, description: "Reviews a diff.", body: "You review.\n", extra: "")
      "---\n#{name ? "name: #{name}\n" : ""}description: #{description}\n#{extra}---\n#{body}"
    end
end
