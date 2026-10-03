require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::InputContentEditTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    png = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
    @picture = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(png), filename: "diagram.png", content_type: "image/png"
      )
    )
  end

  test "clearing a queued message's text keeps its image through materialization and fences stale edits" do
    conversation = create_conversation!
    path = conversation_inputs_path(conversation)
    input = enqueue_picture(path)

    cleared = clear_text(path, input)
    assert_operator cleared.fetch("lock_version"), :>, input.fetch("lock_version")

    patch "#{path}/#{input.fetch("public_id")}", headers: auth, as: :json,
      params: { input: { text: "stale words", expected_lock_version: input.fetch("lock_version") } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    result = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
    assert_predicate result, :accepted?, result.outcome.to_s
    body = result.value.active_variant.content_bodies.find_by!(role: "content")
    assert_image_only(body)
    assert_empty conversation.conversation_inputs
  end

  test "clearing a queued standalone loop input's text retains the image" do
    loops_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops"
    post loops_path, headers: auth("loop"), as: :json, params: {
      agent_loop: {
        approval_mode: "bypass",
        steps: [{ model: { key: "seed", model: { model: "dev/mock-text" }, prompt: "seed" } }],
      },
    }
    assert_response :created
    loop_id = response.parsed_body.dig("agent_loop", "public_id")
    path = "#{loops_path}/#{loop_id}/inputs"
    input = enqueue_picture(path)

    clear_text(path, input)

    assert_image_only(ConversationInput.find_by!(public_id: input.fetch("public_id")).content_body)
  end

  test "an omitted or null text leaves a queued message's words and image unchanged" do
    path = conversation_inputs_path(create_conversation!)
    input = enqueue_picture(path)

    [{ visible_in_context: false }, { text: nil }].each do |changes|
      patch "#{path}/#{input.fetch("public_id")}", headers: auth, as: :json,
        params: { input: changes }
      assert_response :success
      assert_equal "remove these words", response.parsed_body.dig("input", "text")
      assert_equal [@picture.public_id], response.parsed_body.dig("input", "attachments").pluck("public_id")
    end
  end

  private

    def enqueue_picture(path)
      post path, headers: auth("picture"), as: :json,
        params: { input: { text: "remove these words", attachments: [@picture.public_id] } }
      assert_response :accepted
      response.parsed_body.fetch("input")
    end

    def clear_text(path, input)
      patch "#{path}/#{input.fetch("public_id")}", headers: auth, as: :json,
        params: { input: { text: "", expected_lock_version: input.fetch("lock_version") } }
      assert_response :success
      cleared = response.parsed_body.fetch("input")
      assert_equal "", cleared.fetch("text"), "explicit empty text removes the words, not the image"
      assert_equal [@picture.public_id], cleared.fetch("attachments").pluck("public_id")
      cleared
    end

    def assert_image_only(body)
      assert_equal "", body.effective_text
      assert_equal [@picture.public_id], body.upload_parts.map(&:public_id)
      assert_equal [{ "role" => "user", "parts" => [
        { "type" => "upload", "upload_public_id" => @picture.public_id },
      ] }], body.content_body_entries.map { |entry| entry.content_fragment.payload }
    end
end
