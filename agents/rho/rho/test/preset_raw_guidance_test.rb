require "test_helper"

class PresetRawGuidanceTest < Minitest::Test
  def test_raw_guidance_uses_the_resolved_prompt_and_keeps_explicit_request_instructions
    registry = Rho::Runner::Extensions::Registry.new
    prompt = "Replacement\n\nMore"
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
