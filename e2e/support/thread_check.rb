require "uri"
require_relative "gallery/thread"

module E2E
  # THE THREAD EQUALS THE GRAPH'S TREE: one assertion a journey makes on a settled loop. The page is
  # walked to its end, every branch it names is expanded through `?prefix=`, and the tree that comes
  # back is compared whole — `assert_equal`, so minitest names the first disagreement — against the
  # tree the graph route's edges and marks encode (`Gallery.thread_of`). The kernel derives its
  # thread from keys, the mark and the round's reading list; the harness derives its expectation
  # from edges: two derivations, one tree. Structure only, never text. Included beside
  # `LiveJourney`, whose `agent_api` and `loop_path` it reads through.
  module ThreadCheck
    PAGE_LIMIT = 100

    def assert_thread_matches_graph!(loop_id)
      graph = agent_api("#{loop_path(loop_id)}/graph")
      expected = E2E::Gallery.thread_of(graph)
      actual = thread_from_route(loop_id)
      assert_equal expected, actual, "the thread is not the graph's tree:\n#{graph["mermaid"]}"
      actual
    end

    private

      def thread_from_route(loop_id)
        rows = walk_thread(loop_id, nil)
        rows.each do |row|
          assert_equal true, row.fetch("mainline"), "a page row is the mainline: #{row["task_key"]}"
          fan = row.fetch("calls")
          assert_equal fan.fetch("count"), fan.fetch("items").length,
            "#{row["task_key"]} read more calls than a page shows; a fan this wide cannot be compared here"
        end
        mainline = rows.map do |row|
          { "key" => row.fetch("task_key"),
            "calls" => row.fetch("calls").fetch("items").map { |call| call.fetch("task_key") },
            "branches" => row.fetch("branches") }
        end
        branches = rows.flat_map { |row| row.fetch("branches") }.to_h do |call|
          under = walk_thread(loop_id, call)
          under.each { |row| assert_equal false, row.fetch("mainline"), "a branch row is off the mainline: #{row["task_key"]}" }
          [call, under.map { |row| row.fetch("task_key") }]
        end
        { "mainline" => mainline, "branches" => branches }
      end

      # Newest-first behind the cursor, assembled in reading order.
      def walk_thread(loop_id, prefix)
        rows = []
        before = nil
        loop do
          query = { "limit" => PAGE_LIMIT }
          query["before"] = before unless before.nil?
          query["prefix"] = prefix unless prefix.nil?
          page = agent_api("#{loop_path(loop_id)}/transcript?#{URI.encode_www_form(query)}")
          rows = page.fetch("rounds") + rows
          break unless page.dig("pagination", "has_older")

          before = page.dig("pagination", "next_before")
        end
        rows
      end
  end
end
