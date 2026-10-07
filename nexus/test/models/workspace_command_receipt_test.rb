require "test_helper"

class WorkspaceCommandReceiptTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
  end

  test "a receipt freezes its scope, digest, and bounded response snapshot" do
    receipt = WorkspaceCommandReceipt.create!(
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "key-1",
      request_digest: "a" * 64, response_status: 201,
      response_body: { "workspace" => { "public_id" => @workspace.public_id } }
    )

    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(idempotency_key: "other")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(request_digest: "b" * 64)
    end
  end

  test "operation is a closed vocabulary and the key is bounded to 255 bytes" do
    base = {
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      request_digest: "a" * 64, response_status: 201, response_body: {},
    }

    unknown = WorkspaceCommandReceipt.new(base.merge(operation: "workspace_rename", idempotency_key: "k"))
    assert_not unknown.valid?

    blank_key = WorkspaceCommandReceipt.new(base.merge(operation: :workspace_create, idempotency_key: ""))
    assert_not blank_key.valid?

    overlong = WorkspaceCommandReceipt.new(
      base.merge(operation: :workspace_create, idempotency_key: "k" * 256)
    )
    assert_not overlong.valid?

    multibyte = WorkspaceCommandReceipt.new(
      base.merge(operation: :workspace_create, idempotency_key: "汉" * 86)
    )
    assert_not multibyte.valid?, "255 is a byte bound, not a character bound"
  end

  test "the response snapshot is bounded by workspace_command_response_bound" do
    receipt = WorkspaceCommandReceipt.new(
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "big",
      request_digest: "a" * 64, response_status: 201,
      response_body: { "k" => "a" * Nexus::SizeBounds.fetch(:workspace_command_response_bound) }
    )

    assert_not receipt.valid?
    assert receipt.errors.of_kind?(:response_body, :content_too_large)
  end

  test "the same key is unique per actor and account for workspace creates" do
    attributes = {
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "dup",
      request_digest: "a" * 64, response_status: 201, response_body: {},
    }
    WorkspaceCommandReceipt.create!(attributes)

    assert_raises ActiveRecord::RecordNotUnique do
      WorkspaceCommandReceipt.create!(attributes.merge(workspace: workspaces(:personal)))
    end

    # A different actor owns an independent key space.
    assert WorkspaceCommandReceipt.create!(attributes.merge(acting_user: users(:owner))).persisted?
  end

  test "the same key is unique per parent workspace for store entry creates" do
    attributes = {
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      operation: :store_entry_create, idempotency_key: "dup",
      request_digest: "a" * 64, response_status: 201, response_body: {},
    }
    WorkspaceCommandReceipt.create!(attributes)

    assert_raises ActiveRecord::RecordNotUnique do
      WorkspaceCommandReceipt.create!(attributes)
    end

    # The same key under another parent Workspace is a distinct receipt, and
    # the same key may exist for both operations independently.
    assert WorkspaceCommandReceipt.create!(attributes.merge(workspace: workspaces(:personal))).persisted?
    assert WorkspaceCommandReceipt.create!(attributes.merge(operation: :workspace_create)).persisted?
  end

  test "the foreign key cascade remains a structural deletion backstop" do
    receipt = WorkspaceCommandReceipt.create!(
      account: accounts(:cybros), workspace: @workspace, acting_user: users(:member),
      operation: :store_entry_create, idempotency_key: "cascade",
      request_digest: "a" * 64, response_status: 201, response_body: {},
    )

    @workspace.store_entries.delete_all
    Workspace.where(id: @workspace.id).delete_all

    assert_nil WorkspaceCommandReceipt.find_by(id: receipt.id)
  end

  test "digest_for is canonical over key order and covers the operation" do
    first = WorkspaceCommandReceipt.digest_for(
      operation: :workspace_create, envelope: { "name" => "A", "metadata" => { "b" => 1, "a" => 2 } }
    )
    second = WorkspaceCommandReceipt.digest_for(
      operation: :workspace_create, envelope: { "metadata" => { "a" => 2, "b" => 1 }, "name" => "A" }
    )
    other_operation = WorkspaceCommandReceipt.digest_for(
      operation: :store_entry_create, envelope: { "name" => "A", "metadata" => { "a" => 2, "b" => 1 } }
    )

    assert_equal first, second
    assert_not_equal first, other_operation
    assert_match(/\A[0-9a-f]{64}\z/, first)
  end

  test "digest_for distinguishes omission from explicit null" do
    omitted = WorkspaceCommandReceipt.digest_for(
      operation: :store_entry_create, envelope: { "namespace" => "n", "key" => "k" }
    )
    explicit_null = WorkspaceCommandReceipt.digest_for(
      operation: :store_entry_create, envelope: { "namespace" => "n", "key" => "k", "value" => nil }
    )

    assert_not_equal omitted, explicit_null
  end
end
