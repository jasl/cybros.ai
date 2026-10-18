require "test_helper"

# The conversation's access carrier: a three-valued default on the row plus one entry per named
# principal. The creator and the answerer are FULL by derivation — never a row — and
# `access_level_for` is the one Ruby place the derivation lives. No entry validation beyond the
# enum: the unique index is the whole integrity contract.
class ConversationAccessTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @creator = users(:member)
    @answerer = users(:agent)
    @other = users(:curator)
    @conversation = Conversation.create!(
      workspace: @workspace, creating_user: @creator, answering_user: @answerer
    )
  end

  def entry!(user, level, conversation: @conversation)
    conversation.conversation_access_entries.create!(user: user, level: level)
  end

  test "the default is full at birth and the enum refuses a fourth word" do
    assert_equal "full", @conversation.access_default
    assert_predicate @conversation, :access_full?
    assert_equal %w[full read none], Conversation.access_defaults.keys

    @conversation.access_default = "owner"
    assert_not @conversation.valid?
    assert_includes @conversation.errors.details.fetch(:access_default).map { _1[:error] }, :inclusion

    entry = @conversation.conversation_access_entries.build(user: @other, level: "write")
    assert_not entry.valid?
    assert_includes entry.errors.details.fetch(:level).map { _1[:error] }, :inclusion
    assert_equal Conversation.access_defaults, ConversationAccessEntry.levels, "one list, one owner"
  end

  test "the creator and the answerer are full by derivation, whatever the default or an entry says" do
    @conversation.update!(access_default: "none")
    entry!(@creator, "read")
    entry!(@answerer, "none")

    assert_equal "full", @conversation.access_level_for(@creator), "a stray row never demotes the creator"
    assert_equal "full", @conversation.access_level_for(@answerer)
    assert @conversation.readable_by?(@creator)
    assert @conversation.readable_by?(@answerer)
  end

  test "an entry beats the default; the default covers everyone else, the system user included" do
    @conversation.update!(access_default: "read")
    entry!(@other, "none")

    assert_equal "none", @conversation.access_level_for(@other)
    assert_not @conversation.readable_by?(@other), "`none` conceals"
    assert_equal "read", @conversation.access_level_for(users(:owner))
    assert @conversation.readable_by?(users(:owner))
    assert_equal "read", @conversation.access_level_for(users(:system)), "no carve-out for the system user"

    @conversation.update!(access_default: "none")
    assert_equal "none", @conversation.access_level_for(users(:owner))
    assert_not @conversation.readable_by?(users(:owner))

    @conversation.conversation_access_entries.find_by(user: @other).update!(level: "full")
    assert_equal "full", @conversation.access_level_for(@other)
  end

  test "one entry per principal per conversation is the index, and its identity is frozen" do
    entry = entry!(@other, "read")

    assert_equal @conversation.account_id, entry.account_id, "account derives from the conversation (B29)"
    assert_predicate entry, :level_read?
    assert_raises(ActiveRecord::RecordNotUnique) { entry!(@other, "full") }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { entry.update!(user: users(:owner)) }

    second = Conversation.create!(workspace: @workspace, creating_user: @creator)
    assert_nothing_raised { entry!(@other, "full", conversation: second) }
  end

  test "the entries die with the row" do
    entry!(@other, "read")
    entry!(users(:owner), "none")

    assert_difference -> { ConversationAccessEntry.count }, -2 do
      @conversation.destroy!
    end
  end

  # ── the read funnel ─────────────────────────────────────────────

  # Every row of a table of levels × principals: creator, answerer, an entry
  # short of `none` on a `none` default, a `none` entry on a `full` default,
  # a bare `read` default, the workspace OWNER at `none` (no carve-out), the
  # system user — the SQL and the Ruby derivation must agree on each cell.
  test "readable_by is access_level_for spelled in SQL: one answer per cell of the table" do
    owner = users(:owner)
    system = users(:system)
    rows = {
      born_full: @conversation,
      default_none: Conversation.create!(workspace: @workspace, creating_user: @creator,
        answering_user: @answerer, access_default: "none"),
      default_read: Conversation.create!(workspace: @workspace, creating_user: @creator,
        access_default: "read"),
      full_with_none_entry: Conversation.create!(workspace: @workspace, creating_user: @creator),
      none_with_read_entry: Conversation.create!(workspace: @workspace, creating_user: @creator,
        access_default: "none"),
      none_with_full_entry: Conversation.create!(workspace: @workspace, creating_user: @creator,
        access_default: "none"),
    }
    entry!(@other, "none", conversation: rows[:full_with_none_entry])
    entry!(@other, "read", conversation: rows[:none_with_read_entry])
    entry!(owner, "none", conversation: rows[:none_with_read_entry])
    entry!(@other, "full", conversation: rows[:none_with_full_entry])
    entry!(@creator, "none", conversation: rows[:none_with_full_entry])

    [@creator, @answerer, @other, owner, system].each do |user|
      visible = Conversation.readable_by(user).where(id: rows.values.map(&:id)).pluck(:id)
      rows.each do |name, conversation|
        assert_equal conversation.readable_by?(user), visible.include?(conversation.id),
          "#{name} for #{user.display_name}: the SQL and the derivation disagree"
      end
    end

    assert_equal %i[born_full default_read full_with_none_entry].sort,
      rows.select { |_, c| Conversation.readable_by(owner).exists?(id: c.id) }.keys.sort,
      "the owner is nobody special: `none` conceals from the owner too"
    assert_equal %i[born_full default_read none_with_read_entry none_with_full_entry].sort,
      rows.select { |_, c| Conversation.readable_by(@other).exists?(id: c.id) }.keys.sort
    assert_equal rows.keys.sort,
      rows.select { |_, c| Conversation.readable_by(@creator).exists?(id: c.id) }.keys.sort,
      "the creator reads every row, a stray `none` entry notwithstanding"
  end

  test "visible_to is the one funnel: workspace, tombstone and level on one chain, readers filter after it" do
    concealed = Conversation.create!(workspace: @workspace, creating_user: @creator, access_default: "none")
    tombstoned = Conversation.create!(workspace: @workspace, creating_user: @creator,
      tombstoned_at: Time.current)
    elsewhere = Conversation.create!(workspace: workspaces(:personal), creating_user: @other)
    entry!(@other, "read", conversation: elsewhere)

    visible = Conversation.visible_to(@other, workspace: @workspace)
    assert_includes visible, @conversation
    assert_not_includes visible, concealed
    assert_not_includes visible, tombstoned, "a tombstone conceals before the level is read"
    assert_not_includes visible, elsewhere, "another workspace's row, whatever its entry says"

    assert_includes Conversation.visible_to(@creator, workspace: @workspace), concealed

    # The readers' own filters compose AFTER the funnel (the `Relation#or`
    # structural rule): the working list's shape, and a keyset order.
    working = visible.unarchived.where(parent_conversation_id: nil).working
      .includes(:active_turn, :answering_user).order(public_id: :asc)
    assert_equal [@conversation], working.to_a
    assert_equal [], visible.sides.to_a
  end
end
