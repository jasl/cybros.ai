require "test_helper"

class Nexus::TextDeltaChunkingTest < ActiveSupport::TestCase
  test "chunks join back to the original, whitespace tail included" do
    text = "#{"a" * 20_000}\n\n"

    chunks = Nexus::TextDeltaChunking.chunk(text)

    assert_operator chunks.length, :>, 1
    assert_equal text, chunks.join
    chunks.each { |chunk| assert_operator chunk.bytesize, :<=, 16 * 1024 }
  end

  test "a multibyte character is never cut" do
    text = "汉" * 8_000

    chunks = Nexus::TextDeltaChunking.chunk(text, bytes: 16)

    assert_equal text, chunks.join
    chunks.each { |chunk| assert_predicate chunk, :valid_encoding? }
  end

  test "empty text chunks to nothing" do
    assert_empty Nexus::TextDeltaChunking.chunk("")
  end
end
