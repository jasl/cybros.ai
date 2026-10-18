require "test_helper"

# THE KERNEL'S TOOLS BY CAPABILITY: the names a declaration asks for,
# grouped, deduplicated and — when a caller wants the round trip — checked
# against what this deployment actually publishes.
class ToolsetsTest < Minitest::Test
  def entry(canonical) = { "canonical_name" => canonical, "name" => canonical.split(".").last,
                           "effect_profile" => {}, "definition" => {} }

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
  end

  def test_a_group_is_the_canonical_names_a_declaration_asks_for
    assert_equal %w[nexus.graph.delegate_task nexus.graph.wait nexus.human.ask],
      CybrosAgent::Toolsets.names(:orchestration)
    assert_equal CybrosAgent::Toolsets::MEMORY, CybrosAgent::Toolsets.names(:memory)
    assert_predicate CybrosAgent::Toolsets::ALL, :frozen?
  end

  # Order is the order asked, so a declaration reads like the capabilities
  # it chose; a group named twice contributes once.
  def test_several_groups_compose_in_the_order_asked_without_repeating_a_name
    composed = CybrosAgent::Toolsets.names(:skills, :orchestration, :skills)

    assert_equal %w[nexus.skill.load nexus.graph.delegate_task nexus.graph.wait nexus.human.ask], composed
    assert_equal composed, CybrosAgent::Toolsets.names(%i[skills orchestration skills]), "a list reads the same"
  end

  # A typo is a thinner declaration the model discovers for you several
  # rounds later, so it is refused here instead.
  def test_a_word_that_names_no_group_is_refused
    error = assert_raises(ArgumentError) { CybrosAgent::Toolsets.names(:orchestraton) }

    assert_match(/orchestraton/, error.message)
  end

  def test_every_group_holds_canonical_names_this_module_lists_once
    assert_equal CybrosAgent::Toolsets::ALL.uniq, CybrosAgent::Toolsets::ALL
    CybrosAgent::Toolsets::ALL.each do |name|
      assert_match(/\Anexus\.[a-z_]+\.[a-z_]+\z/, name)
    end
    assert_equal CybrosAgent::Toolsets::ALL.sort, CybrosAgent::Toolsets::SETS.values.flatten.sort
  end

  # One catalog read, and the names this deployment does not publish are
  # named together — a boot path checks and declares in one expression.
  def test_verify_answers_the_names_when_the_deployment_serves_them
    served = { "tools" => CybrosAgent::Toolsets::MEMORY.map { |name| entry(name) } }

    assert_equal CybrosAgent::Toolsets::MEMORY,
      CybrosAgent::Toolsets.verify(client([[200, {}, served]]), :memory)
    assert_equal ["/agent_api/v1/tools"], @transport.requests.map { |request| request.fetch(:path) }
  end

  def test_verify_names_every_tool_the_deployment_withholds
    served = { "tools" => [entry("nexus.graph.wait")] }

    error = assert_raises(CybrosAgent::Api::UnknownKernelTool) do
      CybrosAgent::Toolsets.verify(client([[200, {}, served]]), :orchestration)
    end

    assert_match(/nexus\.graph\.delegate_task, nexus\.human\.ask/, error.message)
    refute_match(/nexus\.graph\.wait/, error.message)
  end

  def test_verify_without_a_group_checks_every_name
    served = { "tools" => CybrosAgent::Toolsets::ALL.map { |name| entry(name) } }

    assert_equal CybrosAgent::Toolsets::ALL, CybrosAgent::Toolsets.verify(client([[200, {}, served]]))
  end
end
