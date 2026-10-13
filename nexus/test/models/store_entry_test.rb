require "test_helper"

# The one KV row over three hosts: exactly one anchor, one current value per (namespace, key) per
# host, the same bounds on every host, and never a reader that renders it into a prompt.
class StoreEntryTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    @user = users(:agent)
  end

  test "creation defaults the denormalized account from the host, on every host" do
    workspace_entry = @workspace.store_entries.create!(namespace: "notes", key: "pinned", value: { "ids" => [1] })
    conversation_entry = @conversation.store_entries.create!(namespace: "notes", key: "pinned")
    user_entry = @user.store_entries.create!(namespace: "notes", key: "pinned")

    [workspace_entry, conversation_entry, user_entry].each do |entry|
      assert_equal accounts(:cybros), entry.account
      assert entry.public_id.present?
    end
    assert_equal @workspace, workspace_entry.host
    assert_equal @conversation, conversation_entry.host
    assert_equal @user, user_entry.host
  end

  test "the cap is one number for every host" do
    assert_equal 64, StoreEntry::MAX_ENTRIES_PER_HOST
  end

  test "namespace is constrained to the technical tag shape" do
    ["", "UPPER", "-leading", ".leading", "with space", "a" * (StoreEntry::NAMESPACE_MAX_LENGTH + 1)].each do |namespace|
      entry = @workspace.store_entries.build(namespace: namespace, key: "k")

      assert_not entry.valid?, namespace.inspect
      assert entry.errors[:namespace].any?, namespace.inspect
    end

    assert @workspace.store_entries.build(namespace: "notes.v1_x-y", key: "k").valid?
  end

  test "key is required and bounded" do
    assert_not @workspace.store_entries.build(namespace: "notes", key: "").valid?
    assert_not @workspace.store_entries.build(
      namespace: "notes", key: "k" * (StoreEntry::KEY_MAX_LENGTH + 1)
    ).valid?
  end

  test "namespace and key are unique per host, and the same pair lives on three hosts at once" do
    @workspace.store_entries.create!(namespace: "notes", key: "pinned")
    @conversation.store_entries.create!(namespace: "notes", key: "pinned")
    @user.store_entries.create!(namespace: "notes", key: "pinned")

    duplicate = @workspace.store_entries.build(namespace: "notes", key: "pinned")
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:key, :taken)
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save(validate: false)
    end
    conversation_duplicate = @conversation.store_entries.build(namespace: "notes", key: "pinned")
    assert_not conversation_duplicate.valid?
    assert conversation_duplicate.errors.of_kind?(:key, :taken)
    user_duplicate = @user.store_entries.build(namespace: "notes", key: "pinned")
    assert_not user_duplicate.valid?
    assert user_duplicate.errors.of_kind?(:key, :taken)

    assert @workspace.store_entries.build(namespace: "other", key: "pinned").valid?
    assert workspaces(:personal).store_entries.build(namespace: "notes", key: "pinned").valid?
    assert users(:owner).store_entries.build(namespace: "notes", key: "pinned").valid?
  end

  test "exactly one anchor: two are invalid and none is invalid" do
    two = StoreEntry.new(
      account: accounts(:cybros), workspace: @workspace, conversation: @conversation,
      namespace: "notes", key: "k"
    )
    assert_not two.valid?
    assert two.errors.of_kind?(:base, :exactly_one_anchor)

    none = StoreEntry.new(account: accounts(:cybros), namespace: "notes", key: "k")
    assert_not none.valid?
    assert none.errors.of_kind?(:base, :exactly_one_anchor)
  end

  test "the host scopes answer each host's rows only" do
    workspace_entry = @workspace.store_entries.create!(namespace: "notes", key: "w")
    conversation_entry = @conversation.store_entries.create!(namespace: "notes", key: "c")
    user_entry = @user.store_entries.create!(namespace: "notes", key: "u")

    assert_equal [workspace_entry], StoreEntry.for_workspace(@workspace.id).to_a
    assert_equal [conversation_entry], StoreEntry.for_conversation(@conversation.id).to_a
    assert_equal [user_entry], StoreEntry.for_user(@user.id).to_a
    assert_nil conversation_entry.workspace_id, "a conversation row carries no workspace_id"
  end

  test "anchors, namespace, and key are create-frozen" do
    entry = @workspace.store_entries.create!(namespace: "notes", key: "pinned")

    assert_raises ActiveRecord::ReadonlyAttributeError do
      entry.update(namespace: "moved")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      entry.update(key: "renamed")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      entry.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      entry.update(conversation: @conversation)
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      entry.update(user: @user)
    end
  end

  test "value accepts any JSON value including null and bounded documents" do
    assert @workspace.store_entries.build(namespace: "notes", key: "null", value: nil).valid?
    assert @workspace.store_entries.build(namespace: "notes", key: "list", value: [1, "two"]).valid?
    assert @workspace.store_entries.build(namespace: "notes", key: "scalar", value: 42).valid?
  end

  test "application snapshots larger than a command envelope fit the store" do
    entry = @workspace.store_entries.build(namespace: "state", key: "gateway",
      value: { "data" => "a" * (256 * 1024) })

    assert entry.save
    assert_equal 256 * 1024, entry.reload.value.fetch("data").bytesize
  end

  test "value is bounded by snapshot_bound with the typed rejection" do
    oversize = { "k" => "a" * Nexus::SizeBounds.fetch(:snapshot_bound) }
    entry = @workspace.store_entries.build(namespace: "notes", key: "big", value: oversize)

    assert_not entry.valid?
    assert entry.errors.of_kind?(:value, :content_too_large)
  end

  test "value rejects exponent-form floats before jsonb persistence" do
    entry = @workspace.store_entries.build(
      namespace: "notes", key: "exponent", value: { "value" => 1e308 }
    )

    assert_not entry.save
    assert entry.errors.of_kind?(:value, :unsupported_number)
    assert_not StoreEntry.exists?(entry.id)
  end

  test "optimistic locking detects a stale writer" do
    entry = @workspace.store_entries.create!(namespace: "notes", key: "pinned", value: { "v" => 1 })
    stale = StoreEntry.find(entry.id)

    entry.update!(value: { "v" => 2 })

    assert_raises ActiveRecord::StaleObjectError do
      stale.update!(value: { "v" => 3 })
    end
  end
end
