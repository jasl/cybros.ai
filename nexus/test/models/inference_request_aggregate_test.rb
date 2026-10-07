require "test_helper"

# M1B's closure: the aggregate exists, its status has exactly one authority,
# and the queue row can only be the projection of that authority. The atomic
# create command that assembles all of it is M3's.
class InferenceRequestAggregateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:member)
  end

  def create_inference_request(workload: "text_generation")
    InferenceRequest.create!(
      account: @account, workspace: @workspace, creating_user: @creator,
      workload: workload
    )
  end

  def create_invocation(inference_request: create_inference_request, **overrides)
    DevModelLane.create_invocation!(
      inference_request: inference_request, internal_creation_key: SecureRandom.uuid, **overrides
    )
  end

  # `belongs_to:account, default:` (the house form): absent, the account is the Workspace's; given,
  # it is the caller's word (the account is a singleton, so there is no other word to correct).
  test "a InferenceRequest derives its Account from its immutable Workspace when none is given" do
    inference_request = InferenceRequest.create!(workspace: @workspace, creating_user: @creator, workload: "embedding")

    assert_equal @workspace.account, inference_request.account
    assert_equal "embedding", inference_request.workload
  end

  test "a InferenceRequest rejects a creator outside the Workspace Account" do
    foreign_creator = User.new(account_id: @account.id + 10_000)
    inference_request = InferenceRequest.new(
      account: @account,
      workspace: @workspace,
      creating_user: foreign_creator,
      workload: "text_generation"
    )

    assert_not inference_request.valid?
    assert inference_request.errors.of_kind?(:creating_user, :cross_account)
  end

  test "an invocation derives ownership while keeping its own semantic request facts" do
    inference_request = create_inference_request
    invocation = create_invocation(
      inference_request: inference_request,
      account: Account.new(name: "Wrong"),
      workspace: workspaces(:personal),
      creating_user: users(:owner),
      workload: "image_generation",
      purpose: "wrong",
      provider_id: "semantic-provider",
      model_ref: "semantic-model",
      request_options: { "wrong" => true }
    )

    assert_equal inference_request.account, invocation.account
    assert_equal inference_request.workspace, invocation.workspace
    assert_equal inference_request.creating_user, invocation.creating_user
    assert_equal inference_request.workload, invocation.workload
    assert_equal "semantic-provider", invocation.provider_id
    assert_equal "semantic-model", invocation.model_ref
    assert_equal({ "wrong" => true }, invocation.request_options)
    assert_equal "inference_request", invocation.purpose
  end

  test "the InferenceRequest source facts are creation-frozen" do
    inference_request = create_inference_request

    assert_raises ActiveRecord::ReadonlyAttributeError do
      inference_request.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      inference_request.update(creating_user: users(:owner))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      inference_request.update(workload: "embedding")
    end
  end

  test "status has one authority and the InferenceRequest only reads it" do
    invocation = create_invocation

    assert_equal "queued", invocation.inference_request.status
    assert_not InferenceRequest.column_names.include?("status"),
      "a stored InferenceRequest status would be a second authority to drift"
    assert_not InferenceRequest.column_names.any? { |name| name.include?("invocation_id") },
      "no current-invocation pointer competes with the unique branch FK"

    invocation.update!(status: "canceled", cancellation_reason: "workspace_archived",
      canceled_at: Time.current, terminal_at: Time.current)
    assert_equal "canceled", invocation.inference_request.reload.status
  end

  # A InferenceRequest runs at most twice, and the keys are what say so: its first
  # execution under the aggregate's own key, and one second execution —
  # the creator's fallback after a refusal — under that key's ordinal. The
  # account-scoped key index refuses a second of either.
  test "a InferenceRequest admits one execution per key: its own, then the fallback's ordinal" do
    inference_request = create_inference_request
    DevModelLane.create_invocation!(inference_request: inference_request)

    assert_raises ActiveRecord::RecordNotUnique do
      DevModelLane.create_invocation!(inference_request: inference_request)
    end

    second = "#{ModelInvocation.internal_creation_key_for(inference_request: inference_request)}:#{InferenceRequests::Fallback::ORDINAL}"
    DevModelLane.create_invocation!(inference_request: inference_request, internal_creation_key: second)
    assert_raises ActiveRecord::RecordNotUnique do
      DevModelLane.create_invocation!(inference_request: inference_request, internal_creation_key: second)
    end
  end

  # The invocation namespace is derived, not chosen: the key is a fact about
  # the immutable branch owner. No client supplies one — the create door
  # never passes a key — and the one owner that does is the fallback's
  # second execution, whose ordinal a forced first key would collide with.
  test "the internal creation key is derived from the InferenceRequest unless its owner supplies one" do
    inference_request = create_inference_request

    derived = DevModelLane.create_invocation!(inference_request: inference_request)
    supplied = DevModelLane.create_invocation!(
      inference_request: inference_request, internal_creation_key: "#{derived.internal_creation_key}:2"
    )

    assert_equal ModelInvocation.internal_creation_key_for(inference_request: inference_request), derived.internal_creation_key
    assert_equal "#{derived.internal_creation_key}:2", supplied.internal_creation_key
  end

  test "the key is readable, repeats for one InferenceRequest, and stays in bounds" do
    inference_request = create_inference_request
    key = ModelInvocation.internal_creation_key_for(inference_request: inference_request)

    assert_equal "#{ModelInvocation::INFERENCE_REQUEST_PURPOSE}:#{inference_request.public_id}", key
    assert_equal key, ModelInvocation.internal_creation_key_for(inference_request: inference_request)
    assert_equal key, ModelInvocation.internal_creation_key_for(inference_request: InferenceRequest.find(inference_request.id))
    assert_not_equal key, ModelInvocation.internal_creation_key_for(inference_request: create_inference_request)
    assert_operator key.bytesize, :<=, ModelInvocation::INTERNAL_CREATION_KEY_MAX_BYTES
  end

  # Derivation makes a collision unreachable through the model, so the index
  # is proven the only way left: underneath it.
  test "the account-scoped key index still arbitrates a duplicate" do
    invocation = create_invocation

    assert_raises ActiveRecord::RecordNotUnique do
      ModelInvocation.insert_all!([
        invocation.attributes.except("id", "created_at", "updated_at")
          .merge("public_id" => SecureRandom.uuid_v7, "inference_request_id" => create_inference_request.id),
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

  test "a receipt reserves its replay scope and names exactly one InferenceRequest" do
    inference_request = create_inference_request
    scope = {
      idempotency_key: "key-1",
      request_digest: InferenceRequestCreateReceipt.digest_for(
        workload: inference_request.workload, envelope: { "input" => "hello" }
      ),
    }
    InferenceRequestCreateReceipt.create!(**scope, inference_request: inference_request)

    assert_raises ActiveRecord::RecordNotUnique do
      InferenceRequestCreateReceipt.create!(**scope, inference_request: create_inference_request)
    end
  end

  test "a receipt derives its replay scope from the immutable InferenceRequest" do
    inference_request = create_inference_request
    receipt = InferenceRequestCreateReceipt.create!(
      inference_request: inference_request,
      account: Account.new(name: "Wrong"),
      workspace: workspaces(:personal),
      acting_user: users(:owner),
      workload: "embedding",
      idempotency_key: "derived-scope",
      request_digest: "generated-by-the-request-contract"
    )

    assert_equal inference_request.account, receipt.account
    assert_equal inference_request.workspace, receipt.workspace
    assert_equal inference_request.creating_user, receipt.acting_user
    assert_equal inference_request.workload, receipt.workload

    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      receipt.update(workload: "embedding")
    end
  end

  test "a receipt key uses a byte bound and its generated digest only requires presence" do
    inference_request = create_inference_request
    base = {
      inference_request: inference_request, request_digest: "present-without-format-policy", result: {},
    }

    assert InferenceRequestCreateReceipt.new(**base, idempotency_key: "界" * 85).valid?

    overlong = InferenceRequestCreateReceipt.new(**base, idempotency_key: "#{"界" * 85}a")
    assert_not overlong.valid?
    assert overlong.errors.of_kind?(:idempotency_key, :too_long)

    blank_digest = InferenceRequestCreateReceipt.new(**base, idempotency_key: "blank", request_digest: "")
    assert_not blank_digest.valid?
    assert blank_digest.errors.of_kind?(:request_digest, :blank)
  end

  test "the InferenceRequest request digest has one canonical workload-scoped algorithm" do
    first = InferenceRequestCreateReceipt.digest_for(
      workload: "text_generation",
      envelope: { "input" => { "b" => 1, "a" => "汉字" }, "config" => nil }
    )
    reordered = InferenceRequestCreateReceipt.digest_for(
      workload: "text_generation",
      envelope: { "config" => nil, "input" => { "a" => "汉字", "b" => 1 } }
    )
    other_workload = InferenceRequestCreateReceipt.digest_for(
      workload: "embedding",
      envelope: { "config" => nil, "input" => { "a" => "汉字", "b" => 1 } }
    )

    assert_equal "e73743d565a968a4b6974639523322d8a7f6803f4f1b787ac924131603721650", first
    assert_equal first, reordered
    assert_not_equal first, other_workload
  end

  test "the InferenceRequest request digest distinguishes omission from explicit null" do
    omitted = InferenceRequestCreateReceipt.digest_for(
      workload: "text_generation", envelope: { "input" => "hello" }
    )
    explicit_null = InferenceRequestCreateReceipt.digest_for(
      workload: "text_generation", envelope: { "input" => "hello", "config" => nil }
    )

    assert_not_equal omitted, explicit_null
  end

  test "a body derives its Account from its immutable InferenceRequest owner when none is given" do
    inference_request = create_inference_request
    body = inference_request.content_bodies.build(role: "input")

    assert body.valid?
    assert_equal inference_request.account, body.account
  end

  test "a body names one activated owner branch and its own role vocabulary" do
    inference_request = create_inference_request

    ownerless = ContentBody.new(account: @account, role: "input")
    assert_not ownerless.valid?

    foreign_role = ContentBody.new(account: @account,
      inference_request: inference_request, role: "request")
    assert_not foreign_role.valid?, "`request` belongs to the invocation's vocabulary"
  end
end
