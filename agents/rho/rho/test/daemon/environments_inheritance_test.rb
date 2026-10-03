require_relative "environments_test"

class DaemonEnvironmentsTest
  def test_an_existing_child_binding_controls_the_next_local_placement_after_discovery
    child_store = FakeStore.new([row(value(@other, anchor: "c-child"), public_id: "se-child")])
    client = FakeClient.new(conversations: {
      "c-parent" => FakeConversation.new(store: FakeStore.new([row(value(@project, anchor: "c-parent"))])),
      "c-child" => FakeConversation.new(store: child_store, parent: "c-parent", runner: "0199-runner"),
    })
    table = environments(client, inline: true)
    table.adopt_children("c-parent", ["c-child"])

    assert_equal value(@other, anchor: "c-child"), child_store.entry.value
    placement = table.toolsets.for(task("c-child", parent: "c-parent"))
    assert_equal File.realpath(@other), placement.env.root, "the child row won: its next tool uses its own root"
    assert_equal "c-child", placement.binding.anchor
    assert_equal "se-child", table.memo("c-child").public_id
    assert_equal "conversation", table.memo("c-child").source
  end

  def test_an_existing_child_binding_is_the_value_relayed_to_its_remote_runner
    child_store = FakeStore.new([row(value(@other, anchor: "c-child"), public_id: "se-child")])
    client = FakeClient.new(conversations: {
      "c-parent" => FakeConversation.new(store: FakeStore.new([row(value(@project, anchor: "c-parent"))])),
      "c-child" => FakeConversation.new(store: child_store, parent: "c-parent", runner: "0199-h"),
    }, answers: [relay_answer], executors: {
      "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z"),
    })
    table = environments(client, inline: true)
    table.adopt_children("c-parent", ["c-child"])

    assert_equal value(@other, anchor: "c-child"), child_store.entry.value
    assert_equal 1, client.requests.length
    assert_equal value(@other, anchor: "c-child").merge("conversation_public_id" => "c-child"),
      client.requests.first.fetch(:input), "relay preserves the child's own root and anchor"
    assert_equal binding(@other, anchor: "c-child"), table.binding_for("c-child")
  end

  def test_a_child_binding_created_during_the_parent_walk_wins_over_the_copy
    child_store = FakeStore.new
    create = child_store.method(:create)
    own_value = value(@other, anchor: "c-child")
    child_store.define_singleton_method(:create) do |**attributes|
      create.call(**attributes.merge(value: own_value))
      raise CybrosAgent::Api::Conflict.new("taken", code: "key_taken")
    end
    client = FakeClient.new(conversations: {
      "c-parent" => FakeConversation.new(store: FakeStore.new([row(value(@project, anchor: "c-parent"))])),
      "c-child" => FakeConversation.new(store: child_store, parent: "c-parent"),
    })
    table = environments(client)

    found = table.read("c-child", parent: "c-parent")

    assert_equal own_value, child_store.entry.value
    assert_equal binding(@other, anchor: "c-child"), found.binding
    assert_equal [child_store.entry.public_id, child_store.entry.lock_version], [found.public_id, found.lock_version]
    assert_equal "conversation", found.source
    assert_equal File.realpath(@other), table.toolsets.for(task("c-child", parent: "c-parent")).env.root
  end

  def test_a_failed_read_of_the_existing_child_does_not_publish_a_parent_guess
    child_store = FakeStore.new([row(value(@other, anchor: "c-child"), public_id: "se-child")])
    client = FakeClient.new(conversations: {
      "c-parent" => FakeConversation.new(store: FakeStore.new([row(value(@project, anchor: "c-parent"))])),
      "c-child" => FakeConversation.new(store: child_store, parent: "c-parent", runner: "0199-h"),
    }, answers: [relay_answer], executors: {
      "0199-h" => discovered("0199-h", booted_at: "2026-09-17T06:00:00Z"),
    })
    table = environments(client, inline: true)
    table.read("c-child")
    remembered = table.memo("c-child")
    child_store.fail_reads(CybrosAgent::TransportError.new("offline"))

    assert_raises(Rho::Error) { table.adopt_children("c-parent", ["c-child"]) }

    assert_same remembered, table.memo("c-child")
    assert_empty client.requests
    assert_equal value(@other, anchor: "c-child"), child_store.entry.value
  end
end
