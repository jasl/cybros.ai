require "test_helper"

class UploadsReadTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @upload = accounts(:cybros).content_uploads.create!(creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("attachment bytes"),
        filename: "note.txt", content_type: "text/plain", identify: false))
    sign_in_as @human
  end

  test "cookie bytes support downloads, ranges and conditional reads" do
    get upload_bytes_path(upload_public_id: @upload.public_id)
    assert_response :success
    assert_equal "attachment bytes", response.body
    assert_match(/attachment/, response.headers.fetch("Content-Disposition"))
    assert_includes response.headers.fetch("Cache-Control"), "private"
    tag = response.headers.fetch("ETag")
    get upload_bytes_path(upload_public_id: @upload.public_id), headers: { "Range" => "bytes=0-3" }
    assert_response :partial_content
    assert_equal "atta", response.body
    get upload_bytes_path(upload_public_id: @upload.public_id), headers: { "If-None-Match" => tag }
    assert_response :not_modified
  end

  test "an unreadable upload stays absent for a different signed in account owner" do
    sign_out
    get upload_bytes_path(upload_public_id: @upload.public_id)
    assert_redirected_to new_session_path(return_to: upload_bytes_path(upload_public_id: @upload.public_id))
    sign_in_as users(:owner)
    get upload_bytes_path(upload_public_id: @upload.public_id)
    assert_response :not_found
    get upload_preview_path(upload_public_id: @upload.public_id)
    assert_response :not_found
  end

  test "a readable inherited variant authorizes bytes and loss of that authority takes effect" do
    source = Conversation.create!(workspace: workspaces(:shared), creating_user: @human, access_default: "none")
    seam = create_run_backed_turn(conversation: source, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => "Attached answer" }], seal: true)
    seam.variant.content_bodies.find_by!(role: "content").content_uploads << @upload
    fork = Conversation.create!(workspace: source.workspace, creating_user: users(:curator), access_default: "read")
    ConversationAncestry.create!(account: source.account, conversation: fork, ancestor_conversation: source,
      depth: 1, boundary_position: seam.turn.position)
    sign_out
    sign_in_as users(:owner)
    get upload_bytes_path(upload_public_id: @upload.public_id)
    assert_response :success
    assert_equal "attachment bytes", response.body
    fork.update!(access_default: "none")
    get upload_bytes_path(upload_public_id: @upload.public_id)
    assert_response :not_found
  end

  test "preview uses the shared representation and refuses unsupported files" do
    get upload_preview_path(upload_public_id: @upload.public_id)
    assert_response :not_found
    image = accounts(:cybros).content_uploads.create!(creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PngFixture.bytes(width: 40, height: 30)),
        filename: "picture.png", content_type: "image/png", identify: false))
    get upload_preview_path(upload_public_id: image.public_id)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal [40, 30], PngFixture.dimensions(response.body)
    assert_match(/inline/, response.headers.fetch("Content-Disposition"))
  end
end
