require "test_helper"

class Nexus::DeferredToolsTest < ActiveSupport::TestCase
  Declarations = Nexus::ToolDeclarations
  READ = {
    "type" => "function", "defer_loading" => true,
    "function" => { "name" => "read", "description" => "Read a file",
      "parameters" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } } },
  }.freeze

  def accessors
    %w[tool_search tool_call].map { |name| Nexus::ToolRegistry.function_definition(name) }
  end

  test "only an eager complete accessor pair hides deferred declarations without changing authority" do
    tools = [READ, *accessors]
    original = tools.deep_dup
    assert_equal accessors, Declarations.visible(tools)
    assert_equal original, tools
    assert_equal %w[read tool_search tool_call], Declarations.names(tools)
    assert_equal ["read", { "path" => "a" }, nil], Declarations.resolve_call(tools, "read", { "path" => "a" })
    assert_equal accessors, Declarations.visible([READ.merge("defer_loading" => true), *accessors])
    assert_equal 3, Declarations.visible([READ.merge("defer_loading" => false), *accessors]).length
  end

  test "narrowing without either eager accessor falls back to its complete declaration" do
    [[], [READ], [READ, accessors.first], [READ, accessors.last],
      [READ, accessors.first, accessors.last.merge("defer_loading" => true)]].each do |tools|
      assert_equal tools, Declarations.visible(tools)
    end
  end

  test "aliases can provide the eager pair and retain deferred flags through branch rendering" do
    aliases = [
      { "name" => "FindTool", "canonical" => "nexus.tools.search" },
      { "name" => "InvokeTool", "canonical" => "nexus.tools.call" },
      { "name" => "ReadMemory", "canonical" => "nexus.memory.read", "defer_loading" => true },
    ]
    rendered = Declarations.render(Declarations.canonical(aliases))
    assert_nil Declarations.refusal(rendered)
    assert_equal %w[FindTool InvokeTool], Declarations.names(Declarations.visible(rendered))
    assert_equal rendered, AgentRuns::BranchTools.rerender(rendered)
    assert rendered.find { |entry| Declarations.name_of(entry) == "ReadMemory" }.fetch("defer_loading")
    assert Declarations.wire(rendered).none? { |entry| entry.key?("defer_loading") || entry.key?("canonical") }
  end

  test "kernel presentation annotation is allowed but its canonical schema remains immutable" do
    memory = Nexus::ToolRegistry.function_definition("memory_read").merge("defer_loading" => true)
    assert_nil Declarations.refusal([memory])
    assert_equal [memory], Declarations.render([memory])
    assert_equal [memory], AgentRuns::BranchTools.rerender([memory])
    changed = memory.deep_merge("function" => { "description" => "A different contract" })
    assert_equal "kernel_tool_redefined", Declarations.refusal([changed])
    [nil, "true", 1, []].each do |flag|
      assert_equal "invalid", Declarations.refusal([READ.merge("defer_loading" => flag)])
    end
  end

  test "wire strips routing and presentation while preserving each exact schema" do
    routed = READ.merge("route" => { "kind" => "runner", "runner_executor_public_id" => SecureRandom.uuid,
      "tool_name" => "read" })
    assert_equal [READ.except("defer_loading").deep_merge("function" => { "strict" => false })],
      Declarations.wire([routed])
  end
end
