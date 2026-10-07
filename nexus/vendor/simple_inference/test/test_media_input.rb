require_relative "test_helper"

# The public media boundary normalizes raw bytes once. No paths, URLs, data
# URIs, or caller-asserted types that disagree with the bytes cross it.
class TestMediaInput < Minitest::Test
  PNG = "\x89PNG\r\n\x1a\n".b + ("\x00" * 16)

  def test_normalizes_type_and_size_without_copying_bytes
    input = SimpleInference::MediaInput.from_bytes(PNG)

    assert_equal "image/png", input.media_type
    assert_equal PNG.bytesize, input.byte_size
    assert_same PNG, input.bytes
    assert_predicate input, :frozen?
  end

  def test_accepts_a_matching_declared_type_and_rejects_a_mismatch
    assert SimpleInference::MediaInput.from_bytes(PNG, declared_media_type: "image/png")

    error = assert_raises(SimpleInference::ValidationError) do
      SimpleInference::MediaInput.from_bytes(PNG, declared_media_type: "image/jpeg")
    end
    assert_includes error.message, "image/png"
    assert_includes error.message, "image/jpeg"
  end

  def test_pdf_bytes_keep_their_type_and_reject_a_declared_image_type
    bytes = "%PDF-1.7\n%%EOF\n".b
    input = SimpleInference::MediaInput.from_bytes(bytes, declared_media_type: "application/pdf")

    assert_equal "application/pdf", input.media_type
    assert_same bytes, input.bytes
    assert_equal bytes.bytesize, input.byte_size
    assert_raises(SimpleInference::ValidationError) do
      SimpleInference::MediaInput.from_bytes(bytes, declared_media_type: "image/png")
    end
  end

  def test_rejects_empty_and_undetectable_bytes
    assert_raises(SimpleInference::ValidationError) { SimpleInference::MediaInput.from_bytes("".b) }
    assert_raises(SimpleInference::ValidationError) { SimpleInference::MediaInput.from_bytes("not media".b) }
  end

  def test_rejects_non_binary_carriers
    ["/tmp/cat.png", "https://example.com/cat.png", "data:image/png;base64,AAAA"].each do |carrier|
      error = assert_raises(SimpleInference::ValidationError) do
        SimpleInference::MediaInput.from_bytes(carrier)
      end
      assert_includes error.message, "raw bytes"
    end
  end
end
