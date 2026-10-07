require_relative "test_helper"

# Byte-truth media-type detection: the detected type comes from magic
# numbers, never from a caller-asserted content type or filename.
class TestMediaType < Minitest::Test
  MT = SimpleInference::MediaType

  PNG = "\x89PNG\r\n\x1a\n".b + ("\x00" * 16)
  JPEG = "\xFF\xD8\xFF\xE0".b + ("\x00" * 16)
  WEBP = "RIFF\x20\x00\x00\x00WEBPVP8 ".b
  WAV = "RIFF\x24\x00\x00\x00WAVEfmt ".b
  FLAC = "fLaC\x00\x00\x00\x22".b
  OGG = "OggS\x00\x02".b + ("\x00" * 16)
  MP3_ID3 = "ID3\x04\x00\x00".b + ("\x00" * 16)
  MP3_FRAME = "\xFF\xFB\x90\x00".b + ("\x00" * 16)
  HEIC = "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00".b
  HEIF = "\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00".b
  M4A = "\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00".b
  EBML = "\x1AE\xDF\xA3".b + ("\x00" * 16)

  def static_gif
    # GIF89a, 1x1, no GCT, one image descriptor, trailer.
    ("GIF89a" + "\x01\x00\x01\x00\x00\x00\x00" +
      "\x2C\x00\x00\x00\x00\x01\x00\x01\x00\x00" +
      "\x02\x02\x44\x01\x00" + "\x3B").b
  end

  def test_detects_image_formats_from_bytes
    assert_equal "image/png", MT.detect(PNG)
    assert_equal "image/jpeg", MT.detect(JPEG)
    assert_equal "image/webp", MT.detect(WEBP)
    assert_equal "image/gif", MT.detect(static_gif)
    assert_equal "image/heic", MT.detect(HEIC)
    assert_equal "image/heif", MT.detect(HEIF)
  end

  def test_detects_audio_formats_from_bytes
    assert_equal "audio/wav", MT.detect(WAV)
    assert_equal "audio/flac", MT.detect(FLAC)
    assert_equal "audio/ogg", MT.detect(OGG)
    assert_equal "audio/mpeg", MT.detect(MP3_ID3)
    assert_equal "audio/mpeg", MT.detect(MP3_FRAME)
    assert_equal "audio/mp4", MT.detect(M4A)
    assert_equal "audio/webm", MT.detect(EBML)
  end

  def test_detects_pdf_from_its_header_without_claiming_other_documents
    assert_equal "application/pdf", MT.detect("%PDF-1.7\n%%EOF\n".b)
    assert_equal "application/pdf", MT.detect("%PDF-2.0\n%%EOF\n".b)
    assert_nil MT.detect("PK\x03\x04document-container".b)
    assert_nil MT.detect("a document mentioning %PDF-1.7".b)
  end

  def test_unknown_bytes_detect_as_nil
    assert_nil MT.detect("plain text".b)
    assert_nil MT.detect("".b)
    assert_nil MT.detect(nil)
  end
end
