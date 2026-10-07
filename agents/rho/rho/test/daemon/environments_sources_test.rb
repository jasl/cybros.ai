require_relative "environments_test"

class DaemonEnvironmentsTest
  def test_runner_records_survive_restart_and_clear_independently
    store = FakeStore.new
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: store) })
    table = environments(client)
    table.bind("c-1", root: @project, directories: [], plane: plane(client), runner: "runner-a")
    table.bind("c-1", root: @other, directories: [], plane: plane(client), runner: "runner-b")

    restarted = environments(client)
    assert_equal binding, restarted.binding_for("c-1", plane: plane(client), runner: "runner-a")
    assert_equal binding(@other), restarted.binding_for("c-1", plane: plane(client), runner: "runner-b")
    assert_nil restarted.binding_for("c-1", plane: plane(client), runner: "runner-c")
    assert_equal %w[binding/runner-a binding/runner-b], store.rows.map(&:key).sort

    restarted.clear("c-1", plane: plane(client), runner: "runner-a")
    assert_nil restarted.binding_for("c-1", plane: plane(client), runner: "runner-a")
    assert_equal binding(@other), restarted.binding_for("c-1", plane: plane(client), runner: "runner-b")
  end

  def test_retired_global_record_is_not_inferred_as_a_new_runner_binding
    client = FakeClient.new(conversations: { "c-1" => FakeConversation.new(store: FakeStore.new([row(value, key: "binding")])) })
    table = environments(client)
    assert_nil table.binding_for("c-1", plane: plane(client), runner: "runner-a")
    assert_empty table.binding_targets("c-1", plane: plane(client))
  end
end
