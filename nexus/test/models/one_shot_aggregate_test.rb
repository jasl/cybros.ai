require "test_helper"

# M1B's closure: the aggregate exists, its status has exactly one authority,
# and the queue row can only be the projection of that authority. The atomic
# create command that assembles all of it is M3's.
class OneShotAggregateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
  end

  def create_one_shot(workload: "text_generation")
    OneShot.create!(
      account: @account, workspace: @workspace, creating_user: @creator,
      workload: workload
    )
  end

  def create_invocation(one_shot: create_one_shot, **overrides)
    DevModelLane.create_invocation!(
      one_shot: one_shot, internal_creation_key: SecureRandom.uuid, **overrides
    )
  end

  # `belongs_to:account, default:` (the house form): absent, the account is the Workspace's; given,
  # it is the caller's word (the account is a singleton, so there is no other word to correct).
  test "a OneShot derives its Account from its immutable Workspace when none is given" do
    one_shot = OneShot.create!(workspace: @workspace, creating_user: @creator, workload: "embedding")

    assert_equal @workspace.account, one_shot.account
    assert_equal "embedding", one_shot.workload
  end

  test "a OneShot rejects a creator outside the Workspace Account" do
    foreign_creator = User.new(account_id: @account.id + 10_000)
    one_shot = OneShot.new(
      account: @account,
      workspace: @workspace,
      creating_user: foreign_creator,
      workload: "text_generation"
    )

    assert_not one_shot.valid?
    assert one_shot.errors.of_kind?(:creating_user, :cross_account)
  end

  test "an invocation derives ownership while keeping its own semantic request facts" do
    one_shot = create_one_shot
    invocation = create_invocation(
      one_shot: one_shot,
      account: Account.new(name: "Wrong"),
      workspace: workspaces(:personal),
      creating_user: users(:owner),
      workload: "image_generation",
      purpose: "wrong",
      provider_id: "semantic-provider",
      model_ref: "semantic-model",
      request_options: { "wrong" => true }
    )

    assert_equal one_shot.account, invocation.account
    assert_equal one_shot.workspace, invocation.workspace
    assert_equal one_shot.creating_user, invocation.creating_user
    assert_equal one_shot.workload, invocation.workload
    assert_equal "semantic-provider", invocation.provider_id
    assert_equal "semantic-model", invocation.model_ref
    assert_equal({ "wrong" => true }, invocation.request_options)
    assert_equal "one_shot_attempt", invocation.purpose
  end

  test "the OneShot source facts are creation-frozen" do
    one_shot = create_one_shot

    assert_raises ActiveRecord::ReadonlyAttributeError do
      one_shot.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      one_shot.update(creating_user: users(:owner))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      one_shot.update(workload: "embedding")
    end
  end

  test "status has one authority and the OneShot only reads it" do
    invocation = create_invocation

    assert_equal "queued", invocation.one_shot.status
    assert_not OneShot.column_names.include?("status"),
      "a stored OneShot status would be a second authority to drift"
    assert_not OneShot.column_names.any? { |name| name.include?("invocation_id") },
      "no current-invocation pointer competes with the unique branch FK"

    invocation.update!(status: "canceled", cancellation_reason: "workspace_archived",
      canceled_at: Time.current, terminal_at: Time.current)
    assert_equal "canceled", invocation.one_shot.reload.status
  end

  # A OneShot runs at most twice, and the keys are what say so: its first
  # execution under the aggregate's own key, and one second execution —
  # the creator's fallback after a refusal — under that key's ordinal. The
  # account-scoped key index refuses a second of either.
  test "a OneShot admits one execution per key: its own, then the fallback's ordinal" do
    one_shot = create_one_shot
    DevModelLane.create_invocation!(one_shot: one_shot)

    assert_raises ActiveRecord::RecordNotUnique do
      DevModelLane.create_invocation!(one_shot: one_shot)
    end

    second = "#{ModelInvocation.internal_creation_key_for(one_shot: one_shot)}:#{OneShots::Fallback::ORDINAL}"
    DevModelLane.create_invocation!(one_shot: one_shot, internal_creation_key: second)
    assert_raises ActiveRecord::RecordNotUnique do
      DevModelLane.create_invocation!(one_shot: one_shot, internal_creation_key: second)
    end
  end

  # The invocation namespace is derived, not chosen: the key is a fact about
  # the immutable branch owner. No client supplies one — the create door
  # never passes a key — and the one owner that does is the fallback's
  # second execution, whose ordinal a forced first key would collide with.
  test "the internal creation key is derived from the OneShot unless its owner supplies one" do
    one_shot = create_one_shot

    derived = DevModelLane.create_invocation!(one_shot: one_shot)
    supplied = DevModelLane.create_invocation!(
      one_shot: one_shot, internal_creation_key: "#{derived.internal_creation_key}:2"
    )

    assert_equal ModelInvocation.internal_creation_key_for(one_shot: one_shot), derived.internal_creation_key
    assert_equal "#{derived.internal_creation_key}:2", supplied.internal_creation_key
  end

  test "the key is readable, repeats for one OneShot, and stays in bounds" do
    one_shot = create_one_shot
    key = ModelInvocation.internal_creation_key_for(one_shot: one_shot)

    assert_equal "#{ModelInvocation::ONE_SHOT_PURPOSE}:#{one_shot.public_id}", key
    assert_equal key, ModelInvocation.internal_creation_key_for(one_shot: one_shot)
    assert_equal key, ModelInvocation.internal_creation_key_for(one_shot: OneShot.find(one_shot.id))
    assert_not_equal key, ModelInvocation.internal_creation_key_for(one_shot: create_one_shot)
    assert_operator key.bytesize, :<=, ModelInvocation::INTERNAL_CREATION_KEY_MAX_BYTES
  end

  # Derivation makes a collision unreachable through the model, so the index
  # is proven the only way left: underneath it.
  test "the account-scoped key index still arbitrates a duplicate" do
    invocation = create_invocation

    assert_raises ActiveRecord::RecordNotUnique do
      ModelInvocation.insert_all!([
        invocation.attributes.except("id", "created_at", "updated_at")
          .merge("public_id" => SecureRandom.uuid_v7, "one_shot_id" => create_one_shot.id),
      ])
    end
  end

  test "the request definition is immutable while scheduling stays writable" do
    invocation = create_invocation(priority: 3)

    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(creating_user: users(:owner))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(workload: "embedding")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(internal_creation_key: "rewritten")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(provider_id: "other")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(model_ref: "other")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(reasoning_effort: "low")
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(request_options: { "temperature" => 2.0 })
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(admission_deadline_seconds: 1)
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      invocation.update(priority: 4)
    end
    # Deferral rewrites this while the invocation stays queued.
    invocation.update!(next_admission_at: 5.minutes.from_now)
    assert_predicate invocation.reload.next_admission_at, :present?
  end

  test "a receipt reserves its replay scope and names exactly one OneShot" do
    one_shot = create_one_shot
    scope = {
      idempotency_key: "key-1",
      request_digest: OneShotCreateReceipt.digest_for(
        workload: one_shot.workload, envelope: { "input" => "hello" }
      ),
    }
    OneShotCreateReceipt.create!(**scope, one_shot: one_shot)

    assert_raises ActiveRecord::RecordNotUnique do
      OneShotCreateReceipt.create!(**scope, one_shot: create_one_shot)
    end
  end

  test "a receipt derives its replay scope from the immutable OneShot" do
    one_shot = create_one_shot
    receipt = OneShotCreateReceipt.create!(
      one_shot: one_shot,
      account: Account.new(name: "Wrong"),
      workspace: workspaces(:personal),
      acting_user: users(:owner),
      workload: "embedding",
      idempotency_key: "derived-scope",
      request_digest: "generated-by-the-request-contract"
    )

    assert_equal one_shot.account, receipt.account
    assert_equal one_shot.workspace, receipt.workspace
    assert_equal one_shot.creating_user, receipt.acting_user
    assert_equal one_shot.workload, receipt.workload

    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(workload: "embedding")
    end
  end

  test "a receipt key uses a byte bound and its generated digest only requires presence" do
    one_shot = create_one_shot
    base = {
      one_shot: one_shot, request_digest: "present-without-format-policy", result: {},
    }

    assert OneShotCreateReceipt.new(**base, idempotency_key: "界" * 85).valid?

    overlong = OneShotCreateReceipt.new(**base, idempotency_key: "#{"界" * 85}a")
    assert_not overlong.valid?
    assert overlong.errors.of_kind?(:idempotency_key, :too_long)

    blank_digest = OneShotCreateReceipt.new(**base, idempotency_key: "blank", request_digest: "")
    assert_not blank_digest.valid?
    assert blank_digest.errors.of_kind?(:request_digest, :blank)
  end

  test "the OneShot request digest has one canonical workload-scoped algorithm" do
    first = OneShotCreateReceipt.digest_for(
      workload: "text_generation",
      envelope: { "input" => { "b" => 1, "a" => "汉字" }, "config" => nil }
    )
    reordered = OneShotCreateReceipt.digest_for(
      workload: "text_generation",
      envelope: { "config" => nil, "input" => { "a" => "汉字", "b" => 1 } }
    )
    other_workload = OneShotCreateReceipt.digest_for(
      workload: "embedding",
      envelope: { "config" => nil, "input" => { "a" => "汉字", "b" => 1 } }
    )

    assert_equal "e73743d565a968a4b6974639523322d8a7f6803f4f1b787ac924131603721650", first
    assert_equal first, reordered
    assert_not_equal first, other_workload
  end

  test "the OneShot request digest distinguishes omission from explicit null" do
    omitted = OneShotCreateReceipt.digest_for(
      workload: "text_generation", envelope: { "input" => "hello" }
    )
    explicit_null = OneShotCreateReceipt.digest_for(
      workload: "text_generation", envelope: { "input" => "hello", "config" => nil }
    )

    assert_not_equal omitted, explicit_null
  end

  test "a body derives its Account from its immutable OneShot owner when none is given" do
    one_shot = create_one_shot
    body = one_shot.content_bodies.build(role: "input")

    assert body.valid?
    assert_equal one_shot.account, body.account
  end

  test "a body names one activated owner branch and its own role vocabulary" do
    one_shot = create_one_shot

    ownerless = ContentBody.new(account: @account, role: "input")
    assert_not ownerless.valid?

    foreign_role = ContentBody.new(account: @account,
      one_shot: one_shot, role: "request")
    assert_not foreign_role.valid?, "`request` belongs to the invocation's vocabulary"
  end
end
