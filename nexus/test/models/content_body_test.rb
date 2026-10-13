require "test_helper"

# THE ONE PROJECTION FOR EVERY READER: a body's ordered parts and the bound row at each `upload`
# occurrence — history, the presenter, the summarizer's rendering and rho's `inputs` line all read
# this — and the nil-safe effective text, so a picture with no words never renders its canonical
# JSON.
class ContentBodyTest < ActiveSupport::TestCase
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
  end

  def upload(filename)
    @account.content_uploads.create!(
      creating_user: users(:member),
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: filename, content_type: "image/png")
    )
  end

  def part(type, **fields) = { "type" => type }.merge(fields)

  test "parts and upload_parts read the entries' order, the same row at every occurrence" do
    first = upload("first.png")
    second = upload("second.png")
    entries = [{
      "role" => "user",
      "parts" => [
        part("upload", "upload_public_id" => second.public_id),
        part("text", "text" => "between"),
        part("upload", "upload_public_id" => first.public_id),
        part("upload", "upload_public_id" => second.public_id),
      ],
    }]
    # Bound in the OPPOSITE order to the parts: the join is liveness, never order.
    body = ContentBodies::Replace.call(
      owner: @inference_request, role: "input", entries: entries, uploads: [first, second], readable_text: "between"
    ).body

    assert_equal %w[upload text upload upload], body.parts.map(&:type)
    assert_equal [second, first, second].map(&:id), body.upload_parts.map(&:id),
      "entry order, the row repeated where the part repeats"
    assert_equal "between", body.effective_text
  end

  test "a body of plain text entries has no parts and no upload parts" do
    body = ContentBodies::Replace.call(
      owner: @inference_request, role: "input", entries: [{ "text" => "one" }, { "text" => "two" }]
    ).body

    assert_empty body.parts
    assert_empty body.upload_parts
  end

  test "a picture with no words is a message with no words, never its canonical JSON" do
    picture = upload("alone.png")
    entries = [{ "role" => "user", "parts" => [part("upload", "upload_public_id" => picture.public_id)] }]
    body = ContentBodies::Replace.call(
      owner: @inference_request, role: "input", entries: entries, uploads: [picture], readable_text: ""
    ).body

    assert_equal "", body.readable_text
    assert_equal "", body.effective_text, "the door said `no words`; the canonical entry is not the words"
    assert_equal 0, body.byte_size, "the bytes effective_text answers"
    assert_equal [picture.id], body.upload_parts.map(&:id)
  end

  test "upload_parts reads no entry for a body that binds nothing" do
    body = ContentBodies::Replace.call(
      owner: @inference_request, role: "input", entries: [{ "text" => "words" }]
    ).body
    loaded = ContentBody.preload(:content_uploads).find(body.id)

    assert_no_queries { assert_empty loaded.upload_parts }
  end
end
