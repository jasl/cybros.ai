require "test_helper"
require "open3"
require "rbconfig"

class MemoryPolicyTest < Minitest::Test
  def test_run_declaration_loads_its_memory_policy_when_required_directly
    # Library consumers load the SDK without booting rho's application entry point.
    output, status = Open3.capture2e({ "RUBYOPT" => nil }, RbConfig.ruby,
      "-rbundler/setup", "-I", File.expand_path("../lib", __dir__), "-e",
      'require "cybros_agent"; require "rho/run_declaration"; print Rho::RunDeclaration::GUIDELINE')

    assert_predicate status, :success?, output
    assert_includes output, Rho::MemoryPolicy::PROMPT
  end

  def test_main_profile_and_default_standalone_prompts_share_the_memory_policy
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    policy = Rho::MemoryPolicy::PROMPT
    [Rho::RunDeclaration::GUIDELINE,
      Rho::RunDeclaration.instructions(registry: registry),
      Rho::RunDeclaration.remote_instructions(nil)].each do |prompt|
      assert_equal 1, prompt.scan(policy).length
    end
    refute_includes Rho::RunDeclaration.lead(registry: registry), policy
    refute_includes Rho::RunDeclaration.remote_lead(nil), policy
  end

  def test_explicit_standalone_instructions_keep_the_callers_policy
    registry = Rho::Extensions.load(host: RhoTest.host).registry

    assert_equal "Answer only from the supplied text.",
      Rho::RunDeclaration.instructions(registry: registry, instructions: "Answer only from the supplied text.")
    assert_equal "Answer only from the supplied text.",
      Rho::RunDeclaration.remote_instructions(nil, instructions: "Answer only from the supplied text.")
  end
end
