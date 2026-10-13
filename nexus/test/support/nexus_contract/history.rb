module Nexus
  module Contract
    class << self
      private

        # Plain-text read envelopes; request tests pin these fields against the
        # real routes, and SDK consumers use the same bilingual examples.
        def history
          conversation = "01900000-0000-7000-8000-000000000070"
          turn = "01900000-0000-7000-8000-000000000071"
          pack = {
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
                "public_id" => turn, "position" => 2, "kind" => "direct_reply", "role" => "assistant", "status" => "completed",
                "created_at" => "2026-09-29T00:00:00Z", "prompt" => "Research 人工智能",
                "steers" => "Use the latest notes.", "content" => "人工智能 research is running.", "truncated" => false,
              }],
              "pagination" => { "before_position" => 2, "after_position" => 2, "has_older" => true, "has_newer" => false },
              "truncated" => false,
            },
          }
          execution = thread_page_fixture.merge(
            "turn_public_id" => turn, "variant_public_id" => "01900000-0000-7000-8000-000000000073",
            "active" => true, "status" => "running", "run_public_id" => "01900000-0000-7000-8000-000000000074",
            "run_status" => "running", "truncated" => false
          )
          execution.fetch("rounds").each do |round|
            round.fetch("calls").fetch("items").each { |call| call.except!("title", "metadata") }
          end
          execution["pagination"]["next_before"] = AgentRunTask::TranscriptCursor.encode(1)
          running = pack.fetch("read_fixture").deep_dup
          running.fetch("turns").sole["status"] = "running"
          pack["execution_fixture"] = running.merge("execution" => execution)
          pack["execution_pruned_fixture"] = pack.fetch("read_fixture").merge(
            "execution" => execution.merge("status" => "completed", "run_status" => "completed",
              "details_pruned_at" => "2026-10-01T00:00:00Z", "rounds" => [],
              "pagination" => { "next_before" => nil, "has_older" => false })
          )
          pack
        end
    end
  end
end
