require "test_helper"

class TelegramMediaUpdateTest < Minitest::Test
  def test_photo_caption_mentions_trigger_the_group_and_keep_largest_photo
    update = build("caption" => "🌱 @rho_bot explain this", "caption_entities" => [
      { "type" => "mention", "offset" => 3, "length" => 8 },
    ], "photo" => [{ "file_id" => "small", "file_size" => 10 }, { "file_id" => "large", "file_size" => 30 }])

    assert_equal "🌱 @rho_bot explain this", update.text
    assert update.triggers?("id" => 42, "username" => "rho_bot")
    assert_equal "large", update.media.fetch("file_id")
    assert_equal "image", update.media.fetch("kind")
  end

  def test_captionless_image_document_is_media_but_not_a_group_trigger
    update = build("document" => { "file_id" => "image", "file_name" => "diagram.png",
      "mime_type" => "image/png", "file_size" => 50 })

    assert_empty update.text
    refute update.triggers?("id" => 42, "username" => "rho_bot")
    assert_equal "diagram.png", update.media.fetch("filename")
  end

  def test_voice_note_is_distinct_from_uploaded_audio
    voice = build("voice" => { "file_id" => "voice", "mime_type" => "audio/ogg", "file_size" => 40 })
    audio = build("audio" => { "file_id" => "song", "mime_type" => "audio/mpeg", "file_size" => 50 })

    assert_equal "voice", voice.media.fetch("kind")
    assert_nil audio.media
    assert audio.unsupported_media?
  end

  def test_documents_keep_the_filename_and_missing_mime_is_a_generic_file
    ["application/pdf", "text/plain", nil].each do |type|
      document = { "file_id" => "file", "file_name" => "report.pdf", "file_size" => 400 }
      document["mime_type"] = type if type
      update = build("document" => document)
      assert_equal "file", update.media.fetch("kind")
      assert_equal "report.pdf", update.media.fetch("filename")
      assert_equal(type || "application/octet-stream", update.media.fetch("content_type"))
      refute update.unsupported_media?
    end
  end

  private

    def build(fields)
      Rho::IngressTelegram::Update.new("update_id" => 1, "message" => {
        "from" => { "id" => 1 }, "chat" => { "id" => -10, "type" => "supergroup" },
      }.merge(fields))
    end
end
