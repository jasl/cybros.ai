require "test_helper"

# C2-4 WP-A: the ordered closed part stream. Placement is a CONTRACT, not a compiler convenience —
# "A compiler may neither append all attachments after the text nor infer message membership from
# Body attachment order." These pin it from the refusing side, because the whole point is what the
# grammar will not let a caller leave unsaid.
class ModelSelection::InputPlacementTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @selection = DevModelLane.selection(workload: "text_generation", account: @account)
  end

  test "a message carries text and upload occurrences in one ordered stream" do
    upload = create_upload
    message = Nexus::TextInputMessage.from_h(
      "role" => "user",
      "parts" => [
        { "type" => "text", "text" => "before" },
        { "type" => "upload", "upload_public_id" => upload.public_id },
        { "type" => "text", "text" => "after" },
      ]
    )

    assert_equal %w[text upload text], message.parts.map(&:type)
    assert_kind_of Nexus::UploadInputPart, message.parts[1]
    assert_equal [upload.public_id], message.upload_public_ids
    # Round-trips through the durable form unchanged: this is what the
    # request digest is taken over.
    assert_equal message, Nexus::TextInputMessage.from_h(message.to_h)
  end

  test "the same upload may occur at several positions and is named once" do
    upload = create_upload
    message = Nexus::TextInputMessage.from_h(
      "role" => "user",
      "parts" => [
        { "type" => "upload", "upload_public_id" => upload.public_id },
        { "type" => "text", "text" => "and again" },
        { "type" => "upload", "upload_public_id" => upload.public_id },
      ]
    )

    assert_equal 3, message.parts.length
    assert_equal [upload.public_id], message.upload_public_ids
  end

  test "an unknown part type refuses rather than being read as text" do
    assert_raises(ArgumentError) do
      Nexus::InputParts.from_h("type" => "image_url", "url" => "https://example.test/x.png")
    end
  end

  test "a bound upload with no occurrence has no placement and refuses" do
    upload = create_upload

    result = normalize(input: [text_message("hello")], uploads: [upload])

    refute_predicate result, :accepted?
    assert_equal :unplaced_input_upload, result.refusal
  end

  # Isolated on purpose: the bound upload IS placed, so only the stranger's
  # occurrence is wrong. It reuses the resolver's own refusal, so a caller
  # still cannot learn from this boundary whether an id exists.
  test "an occurrence naming an unbound upload refuses" do
    bound = create_upload
    stranger = create_upload

    result = normalize(
      input: [mixed_message("look", [bound.public_id, stranger.public_id])],
      uploads: [bound]
    )

    refute_predicate result, :accepted?
    assert_equal :unknown_input_upload, result.refusal
  end

  test "placement and binding order are separate contracts" do
    upload = create_upload

    # Bound twice, placed once: the binding list orders durable rows, the
    # stream answers which message holds the occurrence. Neither derives the
    # other, so this is coherent rather than contradictory.
    result = normalize(
      input: [mixed_message("look", [upload.public_id])], uploads: [upload, upload]
    )

    assert_predicate result, :accepted?
  end

  # A workload whose input has no message structure carries no occurrences,
  # so it stays bound-order only and the placement rule does not reach it.
  test "a structureless workload input is unaffected" do
    audio = create_upload(media_type: "audio/wav", filename: "a.wav")
    selection = DevModelLane.selection(workload: "transcription", account: @account)

    result = ModelSelection::Workloads.normalize_workload_input(
      selection: selection, input: nil, uploads: [audio]
    )

    assert_predicate result, :accepted?
  end

  private

    def text_message(text)
      Nexus::TextInputMessage.from_h(
        "role" => "user", "parts" => [{ "type" => "text", "text" => text }]
      )
    end

    def mixed_message(text, upload_public_ids)
      parts = [{ "type" => "text", "text" => text }]
      upload_public_ids.each do |id|
        parts << { "type" => "upload", "upload_public_id" => id }
      end
      Nexus::TextInputMessage.from_h("role" => "user", "parts" => parts)
    end

    def normalize(input:, uploads:)
      ModelSelection::Workloads.normalize_workload_input(
        selection: @selection, input: input, uploads: uploads
      )
    end

    def create_upload(media_type: "image/png", filename: "tiny.png")
      bytes = "placement-#{SecureRandom.hex(4)}"
      @account.content_uploads.create!(
        creating_user: @creator,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: filename, content_type: media_type
        )
      )
    end
end
