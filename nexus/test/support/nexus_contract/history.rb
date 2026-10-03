module Nexus
  module Contract
    class << self
      private

        # Plain-text read envelopes; request tests pin these fields against the
        # real routes, and SDK consumers use the same bilingual examples.
        def history
          conversation = "01900000-0000-7000-8000-000000000070"
          turn = "01900000-0000-7000-8000-000000000071"
          {
            "search_fixture" => {
              "matches" => [{
                "conversation_public_id" => conversation, "title" => "Research 人工智能",
                "turn_public_id" => turn, "variant_public_id" => "01900000-0000-7000-8000-000000000073",
                "position" => 2, "field" => "content", "inherited" => false,
                "excerpt" => "人工智能 research is running.", "truncated" => false,
              }], "pagination" => { "next_after" => nil },
            },
            "read_fixture" => {
              "conversation" => { "public_id" => conversation, "title" => "Research 人工智能" },
              "turns" => [{
                "public_id" => turn, "position" => 2, "kind" => "direct_reply", "role" => "assistant",
                "created_at" => "2026-09-29T00:00:00Z", "prompt" => "Research 人工智能",
                "steers" => "Use the latest notes.", "content" => "人工智能 research is running.", "truncated" => false,
              }],
              "pagination" => { "before_position" => 2, "after_position" => 2, "has_older" => true, "has_newer" => false },
              "truncated" => false,
            },
          }
        end
    end
  end
end
