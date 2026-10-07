require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunInputsTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper

  # THE LOOP DOOR: the conversation's waiting-room surface at the loop's address — a message drained
  # as the person's trailing words.
  test "the loop door accepts a steer, replays it by key, and refuses a different body under the key" do
    loop_id = create_loop!
    post "#{loops_path}/#{loop_id}/start", headers: auth
    assert_response :success

    post "#{loops_path}/#{loop_id}/inputs", headers: auth("in-1"), as: :json,
      params: { input: { text: "use postgres", delivery_mode: "steer" } }
    assert_response :accepted
    input = response.parsed_body.fetch("input")
    assert_equal "steering", input["state"], "a loop host binds every steer to its one turn"
    assert_equal "message", input["kind"]
    assert_equal "user", input["role"]
    assert_equal "use postgres", input["text"]
    assert_nil input["context_mode"], "a field the door never accepts is not rendered"
    assert_nil input["context_options"]

    post "#{loops_path}/#{loop_id}/inputs", headers: auth("in-1"), as: :json,
      params: { input: { text: "use postgres", delivery_mode: "steer" } }
    assert_response :success
    assert_equal input.fetch("public_id"), response.parsed_body.dig("input", "public_id")

    post "#{loops_path}/#{loop_id}/inputs", headers: auth("in-1"), as: :json,
      params: { input: { text: "use sqlite", delivery_mode: "steer" } }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")

    get "#{loops_path}/#{loop_id}/inputs", headers: auth
    assert_response :success
    assert_equal [input.fetch("public_id")], response.parsed_body.fetch("inputs").map { |row| row["public_id"] }
    assert_equal({ "limit" => AgentRun::INPUT_QUEUE_LIMIT, "held" => 1 },
      response.parsed_body.fetch("input_queue"))

    get "#{loops_path}/#{loop_id}", headers: auth
    assert_equal({ "status" => "running" }, response.parsed_body.dig("run", "turn"))
    assert_equal 1, response.parsed_body.dig("run", "input_queue", "held")
  end

  # A LOOP'S ONE TURN IS IN FLIGHT from create to terminal: nothing waits behind it, so nothing on
  # it can wait for a time. The door refuses the field BY NAME — `AgentRun::ADMITTED_INPUT_FIELDS`
  # does not list it — on the create and on the PATCH alike.
  test "the loop door refuses a time by name on create and on PATCH" do
    loop_id = create_loop!
    first = post_input(loop_id, "first", delivery_mode: "queue")

    patch "#{loops_path}/#{loop_id}/inputs/#{first["public_id"]}", headers: auth, as: :json,
      params: { input: { deliver_in: "1h" } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal "Deliver at is not admitted on this host", response.parsed_body.dig("error", "message"),
      "refused by the field's name, as the family renders every field"

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "later", delivery_mode: "queue", deliver_at: "2027-01-01T00:00:00Z" } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal "Deliver at is not admitted on this host", response.parsed_body.dig("error", "message")
    assert_nil ConversationInput.find_by!(public_id: first["public_id"]).deliver_at
  end

  test "the loop door edits and reorders queued follow-ups, and a DELETE on a steer is its cancel" do
    loop_id = create_loop!
    first = post_input(loop_id, "first", delivery_mode: "queue")
    second = post_input(loop_id, "second", delivery_mode: "queue")
    steer = post_input(loop_id, "now", delivery_mode: "steer")

    patch "#{loops_path}/#{loop_id}/inputs/#{first["public_id"]}", headers: auth, as: :json,
      params: { input: { text: "first, edited", expected_lock_version: first["lock_version"] } }
    assert_response :success
    assert_equal "first, edited", response.parsed_body.dig("input", "text")

    patch "#{loops_path}/#{loop_id}/inputs/#{steer["public_id"]}", headers: auth, as: :json,
      params: { input: { text: "never mind" } }
    assert_response :conflict
    assert_equal "steering_held", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/inputs/reorder", headers: auth, as: :json,
      params: { inputs: [second["public_id"], first["public_id"], steer["public_id"]] }
    assert_response :success
    assert_equal [second["public_id"], first["public_id"], steer["public_id"]],
      response.parsed_body.fetch("inputs").map { |row| row["public_id"] }

    delete "#{loops_path}/#{loop_id}/inputs/#{steer["public_id"]}", headers: auth
    assert_response :no_content
    assert_equal 0, loop_record(loop_id).steering_inputs.count
  end

  test "the loop door refuses what it does not admit, by name, and refuses a settled loop" do
    loop_id = create_loop!

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "x", kind: "direct_reply" } }
    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "x", model: { model: "dev/mock-text" }, context_mode: "raw" } }
    assert_response :unprocessable_entity
    assert_match(/model ref.*not admitted|not admitted/i, response.parsed_body.dig("error", "message"))

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "x", tool_names: %w[read_file] } }
    assert_response :unprocessable_entity
    assert_match(/tool names.*not admitted/i, response.parsed_body.dig("error", "message"),
      "the loop's one turn carries its seed's tools; the door refuses the field by name")

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "x", approval_mode: "ask" } }
    assert_response :unprocessable_entity
    assert_match(/approval mode.*not admitted/i, response.parsed_body.dig("error", "message"),
      "the loop's one turn carries its shell's approval word")

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "x", role: "system" } }
    assert_response :unprocessable_entity

    loop_record(loop_id).update!(status: "completed")
    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "too late" } }
    assert_response :conflict
    assert_equal "run_settled", response.parsed_body.dig("error", "code")
    get "#{loops_path}/#{loop_id}/inputs", headers: auth
    assert_response :success, "the queue stays readable on a settled host"
  end

  # A loop-backed loop's door is its conversation's: every verb of the loop
  # door refuses by name, carrying the door it should have knocked on.
  test "every verb of the loop door refuses conversation_hosted on a loop-backed loop" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: @human)
    door = "#{loops_path}/#{seam.agent_run.public_id}/inputs"

    post door, headers: auth(SecureRandom.uuid), as: :json, params: { input: { text: "x" } }
    assert_response :conflict
    error = response.parsed_body.fetch("error")
    assert_equal "conversation_hosted", error["code"]
    assert_equal conversation.public_id, error["conversation_public_id"]
    assert_equal seam.turn.public_id, error["turn_public_id"]

    patch "#{door}/#{SecureRandom.uuid}", headers: auth, as: :json, params: { input: { text: "x" } }
    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
    delete "#{door}/#{SecureRandom.uuid}", headers: auth
    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
    post "#{door}/reorder", headers: auth, as: :json, params: { inputs: [SecureRandom.uuid] }
    assert_response :conflict
    assert_equal "conversation_hosted", response.parsed_body.dig("error", "code")
    assert_equal 0, conversation.conversation_inputs.count, "nothing was forwarded"
  end

  # THE STEP'S PICTURES: `attachments` on a model step through the create door writes the parts
  # input body bound to the creator's uploads; a malformed id refuses positionally; the loop door's
  # own inputs take `attachments` beside `text`.
  test "a model step's attachments ride the create door, and the loop's input door takes them" do
    picture = png_upload
    post loops_path, headers: auth("al-att"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { model: { key: "seed", model: MODEL, prompt: "what is this?", attachments: [picture.public_id] } },
      ] },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("run", "public_id")
    body = loop_record(loop_id).agent_run_tasks.sole.content_bodies.find_by!(role: "input")
    assert_equal %w[text upload],
      body.content_body_entries.sole.content_fragment.payload.fetch("parts").map { |part| part["type"] }
    assert_equal [picture.id], body.content_uploads.map(&:id)

    post loops_path, headers: auth("al-att-bad"), as: :json, params: {
      run: { approval_mode: "bypass", steps: [
        { model: { key: "seed", model: MODEL, prompt: "p", attachments: ["nope"] } },
      ] },
    }
    assert_response :unprocessable_entity
    assert_equal [{ "code" => "invalid_attachments", "path" => "steps[0].attachments" }],
      response.parsed_body.dig("error", "steps")

    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "and this", delivery_mode: "queue", attachments: [picture.public_id] } }
    assert_response :accepted
    assert_equal [picture.public_id], response.parsed_body.dig("input", "attachments").map { |a| a["public_id"] }
    post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
      params: { input: { text: "and this", delivery_mode: "steer", attachments: [picture.public_id] } }
    assert_response :unprocessable_entity
    assert_equal "attachments_not_steerable", response.parsed_body.dig("error", "code")
  end
end
