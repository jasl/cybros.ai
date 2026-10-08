require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationSteeringGuardTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @conversation = create_conversation!
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
  end

  def steer(target: @seam.agent_run.public_id, mode: "steer", key: SecureRandom.uuid, **fields)
    post conversation_inputs_path(@conversation), headers: auth(key), as: :json,
      params: { input: { text: "only this execution", delivery_mode: mode,
        expected_steering_run_public_id: target, **fields } }
  end

  test "the selected loop accepts a guarded steer and exact replay survives its cancellation" do
    steer(target: @seam.agent_run.public_id.upcase, key: "guarded")
    assert_response :accepted
    accepted = response.parsed_body.fetch("input")
    assert_equal "steering", accepted.fetch("state")
    assert_equal @seam.agent_run.public_id, accepted.fetch("expected_steering_run_public_id")
    input = ConversationInput.find_by!(public_id: accepted.fetch("public_id"))
    assert_equal [input.id], @seam.agent_run.steering_inputs.pluck(:id)

    @seam.agent_run.with_lock do
      AgentRuns::Transition.agent_run(@seam.agent_run, status: "canceled", completed_at: Time.current)
    end
    assert_not ConversationInput.exists?(input.id), "a guarded steer never becomes the next turn"
    deleted = @conversation.conversation_event_items.where(item_type: "input_deleted").sole
    assert_equal true, deleted.payload.fetch("steer_canceled")
    assert_equal input.public_id, deleted.payload.fetch("input_public_id")

    steer(key: "guarded")
    assert_response :accepted
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal accepted, response.parsed_body.fetch("input")
    assert_not ConversationInput.exists?(input.id), "replay returns acceptance without recreating the input"

    steer(target: SecureRandom.uuid_v7, key: "guarded")
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "a changed execution refuses without input receipt or event" do
    @seam.variant.update!(status: "completed")
    @seam.turn.update!(status: "completed")
    replacement = create_run_backed_turn(conversation: @conversation, acting_user: @human)

    assert_no_difference ["ConversationInput.count", "ConversationCommandReceipt.count", "ConversationEventItem.count"] do
      steer
      assert_response :conflict
      assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    end
    assert_empty replacement.agent_run.steering_inputs

    steer(target: replacement.agent_run.public_id)
    assert_response :accepted
    assert_equal [replacement.turn.id], ConversationInput.pluck(:steering_target_turn_id)
  end

  test "idle delivered canceled and other addressee targets do not fall back to queue" do
    steer(answering_user_public_id: users(:agent).public_id)
    assert_response :conflict
    assert_equal "steering_target_changed", response.parsed_body.dig("error", "code")
    @seam.agent_run.update!(delivered_at: Time.current)
    steer
    assert_response :conflict
    @seam.agent_run.update!(delivered_at: nil, status: "canceling", canceling_since: Time.current)
    steer
    assert_response :conflict
    @seam.turn.update!(status: "completed")
    steer
    assert_response :conflict
    assert_empty ConversationInput.all

    post conversation_inputs_path(@conversation), headers: auth("unguarded"), as: :json,
      params: { input: { text: "next turn", delivery_mode: "steer" } }
    assert_response :accepted
    assert_equal "pending", response.parsed_body.dig("input", "state")
  end

  test "the guard requires steer and malformed selectors cannot be silently omitted" do
    steer(mode: "queue")
    assert_response :unprocessable_content
    assert_equal "steering_guard_requires_steer", response.parsed_body.dig("error", "code")
    ["broken", [@seam.agent_run.public_id], { id: @seam.agent_run.public_id }].each do |target|
      steer(target: target)
      assert_response :bad_request
      assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
    end
    assert_empty ConversationInput.all
  end

  test "the guard honors merged query parameters before scalar filtering" do
    [SecureRandom.uuid_v7, "broken", @seam.agent_run.public_id.upcase].each_with_index do |target, index|
      query = URI.encode_www_form("input[text]" => "only this execution", "input[delivery_mode]" => "steer",
        "input[expected_steering_run_public_id]" => target)
      post "#{conversation_inputs_path(@conversation)}?#{query}", headers: auth("query-guard-#{index}"), as: :json,
        params: { input: {} }

      assert_response [:conflict, :bad_request, :accepted].fetch(index)
    end
    input = ConversationInput.sole
    assert_equal @seam.agent_run.public_id, input.expected_steering_run_public_id
    assert_equal "steering", input.state
  end

  test "immediate steer keeps its guarded execution and wakes its scheduler" do
    clear_enqueued_jobs
    assert_enqueued_with(job: AgentRuns::ScheduleJob, args: [@seam.agent_run.id]) do
      steer(mode: "steer_now", key: "immediate")
      assert_response :accepted
    end
    accepted = response.parsed_body.fetch("input")
    assert_equal "steer_now", accepted.fetch("delivery_mode")
    assert_equal "steering", accepted.fetch("state")
    assert_equal @seam.agent_run.public_id, accepted.fetch("expected_steering_run_public_id")

    assert_no_enqueued_jobs do
      steer(mode: "steer_now", key: "immediate")
      assert_response :accepted
      assert_equal accepted, response.parsed_body.fetch("input")
    end
  end

  test "send now upgrades a held input without changing its content target or identity" do
    steer
    input = ConversationInput.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    original = input.attributes.except("delivery_mode", "updated_at", "lock_version")
    body_id = input.content_body.id
    version = input.lock_version
    path = "#{conversation_inputs_path(@conversation)}/#{input.public_id}"
    clear_enqueued_jobs

    assert_enqueued_with(job: AgentRuns::ScheduleJob, args: [@seam.agent_run.id]) do
      patch path, headers: auth, as: :json,
        params: { input: { delivery_mode: "steer_now", expected_lock_version: version } }
      assert_response :success
    end
    assert_equal original, input.reload.attributes.except("delivery_mode", "updated_at", "lock_version")
    assert_equal "steer_now", input.delivery_mode
    assert_equal body_id, input.content_body.id
    assert_equal "only this execution", input.text
    assert_equal "steer_now", @conversation.conversation_event_items.where(item_type: "input_edited").sole.payload.fetch("delivery_mode")

    assert_no_difference "ConversationEventItem.count" do
      patch path, headers: auth, as: :json, params: { input: { delivery_mode: "steer_now" } }
      assert_response :success
    end
    patch path, headers: auth, as: :json,
      params: { input: { delivery_mode: "steer_now", expected_lock_version: version } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
  end

  test "send now cannot edit held content or turn a queued row into a different target" do
    steer
    input = ConversationInput.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    path = "#{conversation_inputs_path(@conversation)}/#{input.public_id}"
    patch path, headers: auth, as: :json, params: { input: { delivery_mode: "steer_now", text: "replace" } }
    assert_response :conflict
    assert_equal "steering_held", response.parsed_body.dig("error", "code")
    assert_equal ["steer", "only this execution"], [input.reload.delivery_mode, input.text]

    patch path, headers: auth, as: :json, params: { input: { delivery_mode: "queue" } }
    assert_response :unprocessable_content
    assert_equal "steer", input.reload.delivery_mode

    post conversation_inputs_path(@conversation), headers: auth("queued"), as: :json,
      params: { input: { text: "next turn", delivery_mode: "queue" } }
    queued = response.parsed_body.dig("input", "public_id")
    patch "#{conversation_inputs_path(@conversation)}/#{queued}", headers: auth, as: :json,
      params: { input: { delivery_mode: "steer_now" } }
    assert_response :unprocessable_content
    assert_equal "queue", ConversationInput.find_by!(public_id: queued).delivery_mode
  end

  test "regeneration reads only its own correction and ending the old loop cancels its guard" do
    steer
    assert_response :accepted
    old_input = ConversationInput.find_by!(public_id: response.parsed_body.dig("input", "public_id"))
    @seam.variant.update!(status: "completed")
    variant = @seam.turn.conversation_turn_variants.create!(account: @account, position: 1,
      status: "running", source: "run", origin_variant: @seam.variant)
    replacement = AgentRun.create!(workspace: @workspace, creating_user: @human,
      status: "running", conversation_turn_variant: variant, approval_mode: "bypass")
    assert_empty replacement.steering_inputs
    steer
    assert_response :conflict
    steer(target: replacement.public_id)
    assert_response :accepted
    new_id = response.parsed_body.dig("input", "public_id")
    assert_equal [new_id], replacement.steering_inputs.pluck(:public_id)

    @seam.agent_run.with_lock do
      AgentRuns::Transition.agent_run(@seam.agent_run, status: "canceled", completed_at: Time.current)
    end
    assert_not ConversationInput.exists?(old_input.id)
    assert_equal [new_id], replacement.steering_inputs.pluck(:public_id)
  end
end
