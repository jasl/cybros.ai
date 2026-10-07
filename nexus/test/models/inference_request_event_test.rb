require "test_helper"

# The internal envelope's contract: its idempotency key is immutable and
# scoped per InferenceRequest.
class InferenceRequestEventTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @inference_request = build_inference_request
  end

  test "identity is frozen after insert" do
    event = build_event.tap(&:save!)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      event.update!(idempotency_key: "other")
    end
  end

  test "the key is unique per InferenceRequest and reusable across InferenceRequests" do
    build_event(idempotency_key: "key-1").save!

    assert_raises(ActiveRecord::RecordNotUnique) do
      build_event(idempotency_key: "key-1").save!
    end
    assert build_event(inference_request: build_inference_request, idempotency_key: "key-1").save!
  end

  private

    def build_inference_request
      InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def build_event(inference_request: @inference_request, **overrides)
      InferenceRequestEvent.new(
        account: @account, inference_request: inference_request,
        idempotency_key: SecureRandom.uuid_v7, **overrides
      )
    end
end
