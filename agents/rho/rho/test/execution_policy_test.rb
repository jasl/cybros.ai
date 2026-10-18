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

  # The ordinary prompt keeps the person's work in front of them; moving it
  # to a background worker is a messaging channel's policy, laid by the
  # ingress as a lead and absent from every ordinary prompt.
  def test_ordinary_prompts_work_in_the_foreground_and_leave_background_dispatch_to_the_channel_lead
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    [Rho::RunDeclaration::GUIDELINE, Rho::RunDeclaration.instructions(registry: registry)].each do |prompt|
      assert_includes prompt, "where they can watch it"
      assert_includes prompt, "A messaging channel may add its own delivery policy before the input"
      refute_includes prompt, Rho::ExecutionPolicy::MESSAGING
      refute_match(/briefly acknowledge/, prompt)
    end
    assert_includes Rho::ExecutionPolicy::MESSAGING, "The person sees only your messages, not your work, so reply quickly."
    assert_includes Rho::ExecutionPolicy::MESSAGING, "start one background worker"
    assert_includes Rho::ExecutionPolicy::MESSAGING, "ask one concrete question instead of guessing or starting work"
    refute_includes Rho::RunDeclaration.lead(registry: registry), Rho::ExecutionPolicy::MESSAGING
  end

  def test_messaging_with_subagent_off_requires_direct_work_and_a_completed_result
    assert_equal Rho::ExecutionPolicy::MESSAGING, Rho::ExecutionPolicy.messaging(subagent: true)
    prompt = Rho::ExecutionPolicy.messaging(subagent: false)
    assert_includes prompt, "Carry out the person's work directly in this conversation"
    assert_includes prompt, "Do not spawn or delegate work"
    assert_includes prompt, "Wait for your work to finish and report its result"
    refute_includes prompt, "start one background worker"
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
