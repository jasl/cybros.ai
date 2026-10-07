require "test_helper"

class Conversations::History::TextTest < ActiveSupport::TestCase
  Body = Data.define(:texts) do
    def searchable_texts = texts.each
  end

  test "a search excerpt reports later omitted steer entries without loading the whole body" do
    body = Body.new(texts: ["人工智能 first", "later accepted steer"])
    text, truncated = Conversations::History::Text.excerpt(body, limit: 500, terms: ["人工智能"])
    assert_equal "人工智能 first", text
    assert truncated
    text, truncated = Conversations::History::Text.excerpt(Body.new(texts: ["人工智能 first"]),
      limit: 500, terms: ["人工智能"])
    assert_equal "人工智能 first", text
    assert_not truncated
  end
end
