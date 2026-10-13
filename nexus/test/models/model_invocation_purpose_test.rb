require "test_helper"

# Invocation purposes form a closed ownership matrix — a row carries the owner its purpose names,
# and no other — and this pins both directions, because an owner without its purpose is a second
# authority wearing the first one's name.
class ModelInvocationPurposeTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
  end

  def inference_request
    InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
  end

  test "the one-shot branch derives its facts from the aggregate" do
    invocation = DevModelLane.create_invocation!(inference_request: inference_request)

    assert_equal ModelInvocation::INFERENCE_REQUEST_PURPOSE, invocation.purpose
    assert_equal "interactive", invocation.service_class
    assert_not_nil invocation.workspace_id
  end

  test "the one-shot branch derives its creation key from the aggregate's public identity" do
    shot = inference_request

    assert_equal "#{ModelInvocation::INFERENCE_REQUEST_PURPOSE}:#{shot.public_id}",
      ModelInvocation.internal_creation_key_for(inference_request: shot)
    assert_nil ModelInvocation.internal_creation_key_for(inference_request: nil), "no owner, no key"
  end

  test "an invocation carries exactly one purpose owner" do
    attributes = DevModelLane.invocation_attributes(
      DevModelLane.selection(workload: "text_generation")
    )
    ownerless = ModelInvocation.new(
      account: @account, creating_user: users(:member), workload: "text_generation",
      purpose: ModelInvocation::INFERENCE_REQUEST_PURPOSE, internal_creation_key: "x",
      **attributes
    )
    refute_predicate ownerless, :valid?
    assert_includes ownerless.errors.full_messages.join, "exactly one purpose owner"

    both = ModelInvocation.new(
      inference_request: inference_request, conversation: Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member)),
      **attributes
    )
    refute_predicate both, :valid?
    assert_includes both.errors.full_messages.join, "exactly one purpose owner"
  end

  # The invocation owns its assembled request and its final response and
  # reasoning bodies.
  test "the invocation-owned body branch is scoped to its invocation" do
    invocation = DevModelLane.create_invocation!(inference_request: inference_request)
    body = ContentBody.create!(
      account: @account, model_invocation: invocation,
      role: "response"
    )

    assert_equal [body], invocation.reload.content_bodies.to_a
    assert_includes ContentBody::OWNER_ROLES.fetch(:model_invocation), "request"
  end
end
