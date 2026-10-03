require "test_helper"

# THE LATER CHANGE: a whole replacement of the access carrier — the default and the named entries —
# under the row's own lock, by a principal that is `full` on the row with write standing on the
# workspace (the Windows rule: full control includes changing permissions). Narrated once as
# `access_changed` with the actor's KIND recorded; an unchanged set is a plain acceptance with no
# fact written.
class Conversations::SetAccessTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @creator = users(:member)
    @curator = users(:curator)
    @owner = users(:owner)
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @creator)
  end

  def set_access(by:, default:, entries: [], conversation: @conversation)
    Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
      conversation: conversation, acting_user: by, default: default, entries: entries
    ))
  end

  def entry(user, level) = { "user_public_id" => user.public_id, "level" => level }

  def levels_on(conversation)
    conversation.conversation_access_entries.order(:id).map { |row| [row.user.public_id, row.level] }
  end

  def access_changed_items(conversation) = conversation.conversation_event_items.where(item_type: "access_changed")

  test "the creator replaces the whole set, the fact is narrated with the kind, and an unchanged set writes nothing" do
    result = set_access(by: @creator, default: "none", entries: [entry(@curator, "read"), entry(@owner, "full")])

    assert_predicate result, :accepted?
    assert_equal "none", @conversation.reload.access_default
    assert_equal [[@curator.public_id, "read"], [@owner.public_id, "full"]], levels_on(@conversation)
    fact = access_changed_items(@conversation).sole
    assert_equal({
      "default" => "none",
      "entries" => [{ "user_public_id" => @curator.public_id, "level" => "read" },
                    { "user_public_id" => @owner.public_id, "level" => "full" }],
      "by" => @creator.public_id, "kind" => "human",
    }, fact.payload)

    assert_predicate set_access(by: @creator, default: "none",
      entries: [entry(@curator, "read"), entry(@owner, "full")]), :accepted?
    assert_equal 1, access_changed_items(@conversation).count, "the same set is a read, not a fact"

    # The replacement is WHOLE: a row the new set does not name is gone.
    assert_predicate set_access(by: @creator, default: "read", entries: [entry(@owner, "none")]), :accepted?
    assert_equal "read", @conversation.reload.access_default
    assert_equal [[@owner.public_id, "none"]], levels_on(@conversation)
    assert_equal 2, access_changed_items(@conversation).count
    assert_equal "none", @conversation.access_level_for(@owner)
    assert_equal "read", @conversation.access_level_for(@curator)
  end

  test "the standing is full on the row with workspace write standing: the answerer, a full entry, never read or none" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @creator, answering_user: @agent,
      access_default: "read")
    conversation.conversation_access_entries.create!(user: @curator, level: "full")

    assert_equal :not_authorized, set_access(by: @owner, default: "full", conversation: conversation).outcome,
      "the workspace owner is read here: nobody special (Q-A)"
    assert_equal :not_authorized, set_access(by: @owner, default: "none",
      entries: [entry(@owner, "full")], conversation: conversation).outcome, "no self-escalation from read"
    assert_predicate set_access(by: @agent, default: "none",
      entries: [entry(@curator, "full"), entry(@owner, "read")], conversation: conversation), :accepted?,
      "the answerer is full by derivation"
    assert_equal "agent", access_changed_items(conversation).sole.payload.fetch("kind")
    assert_predicate set_access(by: @curator, default: "read", entries: [entry(@curator, "full")], conversation: conversation),
      :accepted?, "a full ENTRY may narrow the default (full control includes changing permissions)"
    assert_equal "full", conversation.reload.access_level_for(@creator), "the creator is never locked out"

    @workspace.update_column(:state, "archived")
    assert_equal :not_authorized, set_access(by: @creator, default: "full", conversation: conversation).outcome,
      "workspace write standing is the other conjunct"
  ensure
    @workspace.update_column(:state, "active")
  end

  test "a principal that is not eligible refuses by ONE name, before anything is written" do
    @conversation.conversation_access_entries.create!(user: @curator, level: "read")
    refusals = {
      "the creator (full by derivation)" => [entry(@creator, "read")],
      "the answerer (full by derivation)" => [entry(@conversation.answering_user, "read")],
      "the system user" => [entry(users(:system), "read")],
      "an unknown id" => [{ "user_public_id" => SecureRandom.uuid_v7, "level" => "read" }],
      "a repeated id" => [entry(@owner, "read"), entry(@owner, "full")],
    }
    refusals.each do |who, entries|
      result = set_access(by: @creator, default: "none", entries: entries)
      assert_equal :principal_not_eligible, result.outcome, who
    end
    assert_equal "full", @conversation.reload.access_default, "nothing was written"
    assert_equal [[@curator.public_id, "read"]], levels_on(@conversation)
    assert_equal 0, access_changed_items(@conversation).count
  end

  test "an entry names its principal by handle or by public id; a repeat by either spelling is refused" do
    result = set_access(by: @creator, default: "none",
      entries: [{ "handle" => "@curator", "level" => "read" }, { "user_public_id" => @owner.public_id, "level" => "full" }])
    assert_predicate result, :accepted?
    assert_equal [[@curator.public_id, "read"], [@owner.public_id, "full"]], levels_on(@conversation)

    twice = [{ "user_public_id" => @curator.public_id, "level" => "read" }, { "handle" => "curator", "level" => "full" }]
    assert_equal :principal_not_eligible, set_access(by: @creator, default: "none", entries: twice).outcome
    both = [{ "user_public_id" => @curator.public_id, "handle" => "owner", "level" => "read" }]
    assert_equal :principal_not_eligible, set_access(by: @creator, default: "none", entries: both).outcome,
      "an entry spells its principal one way"
    assert_equal :principal_not_eligible, set_access(by: @creator, default: "none",
      entries: [{ "handle" => "@nobody", "level" => "read" }]).outcome
    assert_equal :principal_not_eligible, set_access(by: @creator, default: "none",
      entries: [{ "level" => "read" }]).outcome
    assert_equal [[@curator.public_id, "read"], [@owner.public_id, "full"]], levels_on(@conversation), "nothing written"
  end

  test "an unknown level is invalid — the record carries the error, nothing raises, nothing is written" do
    result = set_access(by: @creator, default: "owner")
    assert_predicate result, :invalid?
    assert_includes result.record.errors.details.fetch(:access_default).map { _1[:error] }, :inclusion

    result = set_access(by: @creator, default: "none", entries: [entry(@curator, "write")])
    assert_predicate result, :invalid?
    assert_includes result.record.errors.details.fetch(:level).map { _1[:error] }, :inclusion

    assert_equal "full", @conversation.reload.access_default
    assert_empty levels_on(@conversation)
    assert_equal 0, access_changed_items(@conversation).count
  end

  test "a tombstone is absence and the archived bin accepts the change" do
    Conversations::Archive.call(conversation: @conversation)
    assert_predicate set_access(by: @creator, default: "read"), :accepted?, "who may read the bin is not content"

    Conversations::Tombstone.call(conversation: @conversation)
    assert_equal :not_found, set_access(by: @creator, default: "full", conversation: @conversation.reload).outcome
  end
end
