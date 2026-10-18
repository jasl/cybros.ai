require_relative "test_helper"

class CodeTest < Minitest::Test
  def test_extension_registers_an_ordinary_tool_on_each_available_address
    [%i[agent runner], [:agent], [:runner]].each do |addresses|
      registrations = []
      api = Object.new
      api.define_singleton_method(:serves?) { |address| addresses.include?(address) }
      api.define_singleton_method(:register_tool) { |klass, serves:| registrations << [klass, serves] }
      Rho::Codemode.register(api)
      assert_equal addresses.map { |address| [Rho::Codemode::Code, address] }, registrations
    end
    Rho::Runner::Extensions::Tool.validate(Rho::Codemode::Code, extension: "rho/codemode")
  end

  def test_adapter_passes_source_to_claim_bridge_and_returns_its_result_unchanged
    calls = []
    result = Rho::Runner::Result.ok("done")
    bridge = Object.new
    bridge.define_singleton_method(:run) do |program:, runtime:|
      calls << [program, runtime]
      result
    end
    context = Object.new
    context.define_singleton_method(:orchestration) { bridge }
    tool = Rho::Codemode::Code.new(env: nil)
    actual = Rho::Runner::ExecutionContext.with(context) { tool.call("code" => "return params;", "params" => false) }
    assert_same result, actual
    assert_equal({ "source" => "return params;", "params" => false }, calls.first.first)
    program = { "source" => "return;", "tools" => [{ "name" => "code", "parameters" => Rho::Codemode::Code::SCHEMA }] }
    assert_equal "finished", calls.first.last.call(program: program).status
  end
end
