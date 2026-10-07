require "test_helper"

class ExecutionPolicyTest < Minitest::Test
  def test_default_execution_prompts_carry_the_same_delegation_and_stage_handoff_policy
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    [Rho::RunDeclaration::GUIDELINE,
      Rho::RunDeclaration.instructions(registry: registry),
      Rho::RunDeclaration.remote_instructions(nil)].each do |prompt|
      assert_equal 1, prompt.scan(Rho::ExecutionPolicy::PROMPT).length
      assert_includes prompt, "Prefer at most three agent levels in total"
      assert_includes prompt, "This is a soft default, not a depth or security limit"
      assert_includes prompt, "A rho binary on a remote Runner alone does not provide access to that directory"
      assert_includes prompt, "ask for an exact model reference or report it unresolved; never guess a model ID"
      assert_includes prompt, "A temporary assignment does not change settings, a named agent's profile or the parent conversation's continuing model"
      assert_includes prompt, "Start a requested review only after the implementation has satisfied its required completion condition"
      assert_includes prompt, "actual final result, access to the changed source or diff, and the checks and artifacts"
    end
  end

  def test_explicit_instructions_remain_the_callers_policy_and_dynamic_leads_do_not_repeat_it
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    instructions = "Use the supplied source only and report to your parent."

    assert_equal instructions, Rho::RunDeclaration.instructions(registry: registry, instructions: instructions)
    assert_equal instructions, Rho::RunDeclaration.remote_instructions(nil, instructions: instructions)
    refute_includes Rho::RunDeclaration.lead(registry: registry), Rho::ExecutionPolicy::PROMPT
    refute_includes Rho::RunDeclaration.remote_lead(nil), Rho::ExecutionPolicy::PROMPT
  end
end
