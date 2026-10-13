require "test_helper"

class Workspace::MessagingTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @sender = users(:agent)
    @recipient = create_agent_member(steward: users(:owner), agent_identifier: "messaging-recipient")
    @other = create_agent_member(steward: users(:owner), agent_identifier: "messaging-other")
  end

  test "the default policy allows every resolved profile" do
    assert_empty @workspace.messaging_policy.agents
    assert @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @sender)
  end

  test "a private recipient accepts listed senders and itself without restricting its outgoing contacts" do
    @workspace.update!(messaging_policy: { agents: [{
      agent_public_id: @recipient.public_id, mode: "private",
      allowed_sender_public_ids: [@sender.public_id],
    }] })

    assert @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert_not @workspace.messaging_allowed?(sender: @other, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @other)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @recipient)
  end

  test "a private recipient with no listed senders permits only self and survives reload" do
    @workspace.update!(messaging_policy: { agents: [{ agent_public_id: @recipient.public_id, mode: "private" }] })
    @workspace.reload

    assert_equal @recipient.public_id, @workspace.messaging_policy.agents.sole.agent_public_id
    assert_empty @workspace.messaging_policy.agents.sole.allowed_sender_public_ids
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @recipient)
    assert_not @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
  end

  test "public recipients retain their sender list without enforcing it" do
    @workspace.update!(messaging_policy: { agents: [{
      agent_public_id: @recipient.public_id, mode: "public",
      allowed_sender_public_ids: [@sender.public_id],
    }] })
    @workspace.reload

    assert_equal [@sender.public_id], @workspace.messaging_policy.agents.sole.allowed_sender_public_ids
    assert @workspace.messaging_allowed?(sender: @other, recipient: @recipient)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @recipient)

    @workspace.messaging_policy.agents.sole.mode = "private"
    @workspace.save!
    @workspace.reload

    assert @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert_not @workspace.messaging_allowed?(sender: @other, recipient: @recipient)
  end

  test "the sender's private policy does not add a second admission condition" do
    @workspace.update!(messaging_policy: { agents: [
      { agent_public_id: @sender.public_id, mode: "private", allowed_sender_public_ids: [] },
      { agent_public_id: @recipient.public_id, mode: "private", allowed_sender_public_ids: [@sender.public_id] },
    ] })

    assert @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert_not @workspace.messaging_allowed?(sender: @recipient, recipient: @sender)
  end

  test "messaging choices do not grant workspace data access" do
    private_workspace = workspaces(:personal)

    assert private_workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
    assert_not private_workspace.data_accessible_by?(@sender)
  end

  test "the predicate does not incorporate lifecycle or dedication state" do
    @workspace = workspaces(:dedicated)
    @workspace.messaging_policy = { agents: [{
      agent_public_id: @recipient.public_id, mode: "private",
      allowed_sender_public_ids: [@sender.public_id],
    }] }
    @recipient.status = "removed"
    @workspace.state = "archived"

    assert @workspace.messaging_allowed?(sender: @sender, recipient: @recipient)
  end

  test "named profiles have independent policies from their paired declarer" do
    named = Users::DeclareNamedDefinition.call(
      caller: @sender, name: "communicator", scope: "steward", description: "A named profile",
      configuration: {
        tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
        prompt_template: nil, compaction_policy: nil, default_model: nil,
      }
    ).user
    @workspace.update!(messaging_policy: { agents: [{ agent_public_id: named.public_id, mode: "private" }] })

    assert_not @workspace.messaging_allowed?(sender: @recipient, recipient: named)
    assert @workspace.messaging_allowed?(sender: @recipient, recipient: @sender)
    assert @workspace.messaging_allowed?(sender: named, recipient: named)
  end
end
