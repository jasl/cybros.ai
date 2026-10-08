require "test_helper"

class WorkPresetsTest < Minitest::Test
  def test_defaults_and_literal_custom_text_resolve_without_changing_the_builtin_prompt
    config = Rho::Config.from_hash({})
    assert_equal "standard", config.work_preset
    assert_nil config.custom_instructions
    assert_nil config.base_prompt
    assert_equal Rho::RunDeclaration::GUIDELINE, config.system_prompt

    text = "  Use 中文.\n\n    Keep this indentation.\n"
    edited = config.with({ "custom_instructions" => text })
    assert_equal text, edited.custom_instructions
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\n#{text}", edited.system_prompt
    assert_equal Rho::RunDeclaration::GUIDELINE, config.system_prompt
  end

  def test_base_replacement_and_restoring_the_preset_preserve_empty_and_whitespace
    config = Rho::Config.from_hash({ "work_preset" => "compact", "base_prompt" => "  Base.\n",
      "custom_instructions" => "  More.\n" })
    assert_equal "  Base.\n\n\n  More.\n", config.system_prompt
    assert_equal "  More.\n", config.with({ "base_prompt" => "" }).system_prompt
    assert_equal "", config.with({ "base_prompt" => "", "custom_instructions" => nil }).system_prompt
    assert_equal "  \n", config.with({ "base_prompt" => "  \n", "custom_instructions" => "" }).system_prompt
    assert_equal "#{Rho::WorkPresets::COMPACT}\n\n  More.\n", config.with({ "base_prompt" => nil }).system_prompt
  end

  def test_settings_validate_the_closed_preset_and_text_types_at_the_config_boundary
    config = Rho::Config.from_hash({ "work_preset" => " Compact " })
    assert_equal "compact", config.work_preset
    error = assert_raises(Rho::ConfigurationError) { config.with({ "work_preset" => "other" }) }
    assert_match(/work_preset must be one of standard, compact/, error.message)
    %w[custom_instructions base_prompt].each do |key|
      [1, false, [], {}].each do |value|
        assert_raises(Rho::ConfigurationError, "#{key}: #{value.inspect}") { config.with({ key => value }) }
      end
    end
  end

  def test_the_combined_prompt_limit_counts_utf8_bytes_including_the_separator
    base = "界" * 21_844
    config = Rho::Config.from_hash({ "base_prompt" => base, "custom_instructions" => "ab" })
    assert_equal 65_536, config.system_prompt.bytesize
    error = assert_raises(Rho::ConfigurationError) { config.with({ "custom_instructions" => "abc" }) }
    assert_match(/at most 64 KiB of UTF-8 text/, error.message)
    assert_equal 65_536, config.with({ "base_prompt" => "x" * 65_536, "custom_instructions" => nil }).system_prompt.bytesize
    assert_raises(Rho::ConfigurationError) { config.with({ "base_prompt" => "x" * 65_537, "custom_instructions" => nil }) }
    assert_raises(Rho::ConfigurationError) { config.with({ "base_prompt" => nil, "custom_instructions" => "x" * 65_536 }) }
  end

  def test_current_config_exposes_the_latest_prompt_without_mutating_a_captured_document
    standard = Rho::Config.from_hash({})
    current = Rho::Config::Current.new(standard)
    before = current.system_prompt
    current.apply(standard.with({ "base_prompt" => "Replacement", "custom_instructions" => "More" }))
    assert_equal "standard", current.work_preset
    assert_equal "Replacement", current.base_prompt
    assert_equal "More", current.custom_instructions
    assert_equal "Replacement\n\nMore", current.system_prompt
    assert_equal Rho::RunDeclaration::GUIDELINE, before
  end

  def test_raw_guidance_uses_the_resolved_prompt_and_keeps_explicit_request_instructions
    registry = Rho::Runner::Extensions::Registry.new
    prompt = Rho::Config.from_hash({ "base_prompt" => "Replacement", "custom_instructions" => "More" }).system_prompt
    expected = "#{prompt}\n\nConversation kind: standalone."
    assert_equal expected, Rho::RunDeclaration.instructions(registry: registry, system_prompt: prompt)
    assert_equal expected, Rho::RunDeclaration.remote_instructions(nil, system_prompt: prompt)
    assert_equal "Explicit", Rho::RunDeclaration.instructions(registry: registry, system_prompt: prompt, instructions: "Explicit")
    assert_equal "Explicit", Rho::RunDeclaration.remote_instructions(nil, system_prompt: prompt, instructions: "Explicit")
    raw = Rho::RunDeclaration.steps(prompt: "Task", model: "dev/model", registry: registry, system_prompt: prompt).first
    assert_equal expected, raw.instructions
    assembled = Rho::RunDeclaration.steps(prompt: "Task", model: "dev/model", registry: registry,
      system_prompt: prompt, prompt_mechanism: "assembly").first
    assert_nil assembled.instructions
    assert_nil raw.tools
    assert_nil assembled.tools
    assert_equal raw.kernel_tools, assembled.kernel_tools
    assert_nil raw.runner_tool_names
    assert_nil assembled.runner_tool_names
  end
end
