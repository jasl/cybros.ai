require "test_helper"

class AgentAPI::V1::Uploads::InheritanceTest < ActionDispatch::IntegrationTest
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @owner = users(:owner)
    @reader = users(:curator)
    @credential = create_access_token_fixture(user: @reader, name: "Fork reader")
    @source = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, access_default: "none")
    @picture = upload("prefix.png")
    @prefix = append_message(attachment: @picture)
    boundary = append_message
    @later_picture = upload("later.png")
    append_message(attachment: @later_picture)
    fork = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @source, turn_public_id: boundary.public_id, variant_public_id: nil,
      acting_user: @owner, title: nil
    ))
    assert_predicate fork, :accepted?
    @child = fork.value
    @child.conversation_access_entries.create!(user: @reader, level: "read")
  end

  test "a child reader can fetch an inherited attachment without source access" do
    read_bytes(@picture)
    assert_response :success
    assert_equal PNG.b, response.body.b

    read_bytes(@later_picture)
    assert_response :not_found, "the child's closure excludes later source turns"

    @child.conversation_access_entries.find_by!(user: @reader).update!(level: "none")
    read_bytes(@picture)
    assert_response :not_found, "the source cannot substitute for the child's current ACL"
  end

  test "a plain fork keeps inherited bytes readable after the source is tombstoned" do
    assert_predicate Conversations::Tombstone.call(conversation: @source), :accepted?

    read_bytes(@picture)

    assert_response :success
    assert_equal PNG.b, response.body.b
  end

  test "a concealed inherited turn supplies no attachment read authority" do
    @child.conversation_turn_overrides.create!(
      account: @child.account, conversation_turn: @prefix, visibility: "visible", deleted_at: Time.current
    )

    read_bytes(@picture)
    assert_response :not_found
  end

  test "a child in an inaccessible workspace supplies no attachment read authority" do
    @source.workspace.update!(access_mode: "private")

    read_bytes(@picture)
    assert_response :not_found
  end

  private

    def upload(filename)
      @source.account.content_uploads.create!(creating_user: @owner,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: filename, content_type: "image/png"))
    end

    def append_message(attachment: nil)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: @source, acting_user: @owner, kind: "message", role: "user", entries: [{ "text" => "look" }],
        attachments: attachment ? [attachment.public_id] : nil, visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil, expected_tail_turn_public_id: nil,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @source.id)
      @source.conversation_turns.order(:position).last
    end

    def read_bytes(upload)
      get agent_api_v1_upload_bytes_path(upload_public_id: upload.public_id),
        headers: { "Authorization" => "Bearer #{@credential.secret}" }
    end
end
