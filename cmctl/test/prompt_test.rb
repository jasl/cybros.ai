require_relative "test_helper"

class PromptTest < Minitest::Test
  def test_numbered_choices_reprompt_and_enter_preserves_the_current_choice
    output = StringIO.new
    prompt = CybrosControl::Prompt.new(input: StringIO.new("0\n3\nno\n\n"), output: output)
    assert_equal 1, prompt.choose("Model", choices: ["One", "Two"], default: 1)
    assert_equal 3, output.string.scan("Enter a number from 1 to 2.").length
  end

  def test_confirm_reprompts_and_uses_an_explicit_default
    prompt = CybrosControl::Prompt.new(input: StringIO.new("maybe\n\nY\n"), output: StringIO.new)
    refute prompt.confirm("Replace?", default: false)
    assert prompt.confirm("Continue?")
  end

  def test_end_of_input_cancels_instead_of_accepting_a_default
    prompt = CybrosControl::Prompt.new(input: StringIO.new, output: StringIO.new)
    assert_raises(CybrosControl::Cancelled) { prompt.ask("Value", default: "old") }
  end
end
