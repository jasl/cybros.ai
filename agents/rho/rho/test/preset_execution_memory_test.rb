require "test_helper"
require "rho/preset_execution"

class PresetExecutionMemoryTest < Minitest::Test
  def test_nil_inherits_the_ceiling_and_an_empty_limit_stays_disabled
    ceiling = { "bindings" => [binding("conversation", "read_write")] }
    assert_equal ceiling, Rho::PresetExecution.limit_memory(nil, ceiling: ceiling)
    assert_equal({ "bindings" => [] }, Rho::PresetExecution.limit_memory({ "bindings" => [] }, ceiling: ceiling))
    assert_equal ceiling, Rho::PresetExecution.limit_memory(ceiling, ceiling: nil)
    assert_nil Rho::PresetExecution.limit_memory(nil, ceiling: nil)
  end

  def test_intersection_never_adds_roots_or_widens_either_sides_access
    authored = { "bindings" => [binding("conversation", "read"), binding("speaker", "read_write"),
      binding("workspace", "read_write"), binding("agent", "read_write")] }
    ceiling = { "bindings" => [binding("workspace", "read"), binding("conversation", "read_write"),
      binding("speaker", "read_write"), binding("user", "read_write")] }
    before = Marshal.dump([authored, ceiling])

    assert_equal({ "bindings" => [binding("conversation", "read"), binding("speaker", "read_write"), binding("workspace", "read")] },
      Rho::PresetExecution.limit_memory(authored, ceiling: ceiling))
    assert_equal({ "bindings" => [] }, Rho::PresetExecution.limit_memory(authored, ceiling: { "bindings" => [] }))
    assert_equal before, Marshal.dump([authored, ceiling])
  end

  def test_a_conversation_only_role_cannot_regain_the_external_bots_other_roots
    authored = { "bindings" => [binding("conversation", "read"), binding("speaker", "read_write"), binding("agent", "read_write")] }
    external = { "bindings" => [binding("conversation", "read_write"), binding("speaker", "read_write")] }
    role = { "bindings" => [binding("conversation", "read_write")] }
    bot = Rho::PresetExecution.limit_memory(authored, ceiling: external)

    assert_equal({ "bindings" => [binding("conversation", "read")] }, Rho::PresetExecution.limit_memory(bot, ceiling: role))
  end

  private

    def binding(scope, access) = { "name" => scope, "scope" => scope, "access" => access }
end
