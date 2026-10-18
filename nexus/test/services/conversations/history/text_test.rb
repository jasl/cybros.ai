require "test_helper"

class Conversations::History::TextTest < ActiveSupport::TestCase
  Body = Data.define(:texts) do
    def searchable_text_parts
      texts.each_with_index.map { |text, index| { text: text, entry_position: index, part_index: 0 } }.each
    end
  end

  test "a search excerpt reports later omitted steer entries without loading the whole body" do
    body = Body.new(texts: ["人工智能 first", "later accepted steer"])
    text, truncated, location = Conversations::History::Text.excerpt(body, limit: 500, terms: ["人工智能"])
    assert_equal "人工智能 first", text
    assert truncated
    assert_equal({ entry_position: 0, part_index: 0, character_offset: 0 }, Conversations::History::Location.decode(location))
    text, truncated = Conversations::History::Text.excerpt(Body.new(texts: ["人工智能 first"]),
      limit: 500, terms: ["人工智能"])
    assert_equal "人工智能 first", text
    assert_not truncated
  end

  test "the excerpt location starts inside the matching later part without a second scan" do
    body = Body.new(texts: ["before", "前言" * 10_000 + "人工智能" + "后记" * 300])
    text, truncated, location = Conversations::History::Text.excerpt(body, limit: 500, terms: ["人工智能"])
    point = Conversations::History::Location.decode(location)
    assert_equal({ entry_position: 1, part_index: 0, character_offset: 19_875 }, point)
    assert_equal body.texts.last[point[:character_offset], 500], text
    assert truncated
  end
end
