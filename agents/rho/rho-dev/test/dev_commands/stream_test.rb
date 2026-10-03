require "support/dev_commands"

class DevCommandsTest
  def test_follow_renders_a_settled_loop_and_says_the_stream_is_over
    daemon = boot
    hold_run(daemon, followed_run("al-1", state: { complete: true },
      tasks: [{ "task_key" => "r1", "status" => "completed" }]))

    ops(:follow, "al-1")

    assert_match(/^\s+completed\s+r1$/, @out.string, @out.string)
    assert_match(/\(stream ended: turn_settled\)/, @out.string, @out.string)
  end

  # THE MODEL'S WORDS IN THEIR OWN BLOCK, and every structured line still
  # anchored under them: the delta leaves the cursor mid-line, and the
  # `(stream ended: …)` line is the first thing that has to survive it.
  def test_follow_prints_what_arrives_while_the_loop_is_still_working
    daemon = boot
    state = { complete: false }
    listeners = Queue.new
    hold_run(daemon, followed_run("al-1", tasks: [], state: state, listeners: listeners))

    follower = Thread.new { ops(:follow, "al-1") }
    handler = listeners.pop # the stream is up once the route has registered
    state[:complete] = true # so this event is also the last
    handler.call(frame("text_delta", { "text" => "half a thought" }))

    assert follower.join(10), "follow never returned, so a settled loop still looks live"
    assert_match(/^#{Regexp.escape(Rho::StreamPrinter::INDENT)}half a thought$/, @out.string, @out.string)
    assert_match(/^\(stream ended: turn_settled\)$/, @out.string, @out.string)
  end

  def test_follow_says_once_that_a_retry_discarded_what_it_printed
    out = follow_frames(
      frame("text_delta", { "text" => "half an ans" }),
      frame("stream_reset", { "reason" => "retry" }),
      frame("text_delta", { "text" => "the answer" })
    )

    gutter = Rho::StreamPrinter::INDENT
    assert_equal ["#{gutter}half an ans", Rho::StreamPrinter::RESET_LINE, "#{gutter}the answer",
                  "(stream ended: turn_settled)"], out.lines.map(&:chomp)
  end

  # ONE KNOB PER CONCERN: reasoning is always accumulated by the follower
  # and printed only when a person asks for it.
  def test_reasoning_is_silent_unless_it_is_asked_for
    out = follow_frames(frame("reasoning_delta", { "kind" => "reasoning_text", "text" => "thinking" }))

    refute_match(/thinking/, out, out)
  end

  def test_reasoning_prints_on_its_own_channel_when_asked_for
    out = follow_frames(frame("reasoning_delta", { "kind" => "reasoning_text", "text" => "thinking" }),
                        reasoning: true)

    assert_match(/^#{Regexp.escape(Rho::StreamPrinter::INDENT)}thinking$/, out, out)
    refute_includes out, "\e", "a captured lane gets no escape codes"
  end

  def test_no_stream_prints_no_model_text_at_all
    out = follow_frames(frame("text_delta", { "text" => "half a thought" }), stream: false)

    refute_match(/half a thought/, out, out)
    assert_match(/^\(stream ended: turn_settled\)$/, out, out)
  end

  # THE JOIN-TIME PARTIAL: the route's first frame is the follower's own
  # snapshot, and what it already accumulated seeds the block.
  def test_the_snapshot_frame_seeds_the_block_with_what_was_already_said
    daemon = boot
    state = { complete: true }
    hold_run(daemon, followed_run("al-1", state: state, tasks: [],
      snapshot: { public_id: "al-1", tasks: [], text: "already said", text_length: 12 }))

    ops(:follow, "al-1")

    assert_match(/^#{Regexp.escape(Rho::StreamPrinter::INDENT)}already said$/, @out.string, @out.string)
  end

  # THE TERMINAL EVENT READER: a person who joins on the events feed's terminal — the turn
  # settled, its text not yet — sees the join-time partial on BOTH channels (the reasoning
  # the reply opened with, then the text so far), then the settle's remainder as it lands,
  # and only then "(stream ended": the whole reply, ahead of the end. The kernel's settled
  # turn carries a text body and no reasoning body, so the remainder is text alone; the
  # transcript box flips settled with that LAST frame, as the follower records it.
  def test_follow_prints_the_whole_reply_when_the_events_terminal_beats_the_settle
    daemon = boot
    state = { complete: true, transcript: false }
    listeners = Queue.new
    hold_run(daemon, followed_run("al-1", tasks: [], state: state, listeners: listeners,
      snapshot: { public_id: "al-1", tasks: [], text: "half an", text_length: 7, reasoning: "thinking" }))

    follower = Thread.new { ops(:follow, "al-1", reasoning: true) }
    handler = listeners.pop
    state[:transcript] = true
    handler.call(frame("text_delta", { "text" => " answer" }))

    assert follower.join(10), "follow never returned"
    gutter = Rho::StreamPrinter::INDENT
    assert_equal ["#{gutter}thinking", "#{gutter}half an answer", "(stream ended: turn_settled)"],
      @out.string.lines.map(&:chomp), @out.string
  end

  # One live follow, the frames delivered in order, the loop settled by
  # the last of them.
  def follow_frames(*frames, **options)
    daemon = boot
    state = { complete: false }
    listeners = Queue.new
    hold_run(daemon, followed_run("al-1", tasks: [], state: state, listeners: listeners))

    follower = Thread.new { ops(:follow, "al-1", **options) }
    handler = listeners.pop
    frames.each_with_index do |item, index|
      state[:complete] = true if index == frames.length - 1
      handler.call(item)
    end
    assert follower.join(10), "follow never returned"
    @out.string
  end

  # The pushed stream renders through the same lines `rho watch` prints:
  # a branch frame in the snapshot indents under its call key, and a
  # later `task_status` for a deeper branch round finds the chain in what
  # the stream already showed.
  def test_follow_indents_a_branch_under_its_call_key_across_frames
    daemon = boot
    state = { complete: false }
    listeners = Queue.new
    hold_run(daemon, followed_run("al-1", state: state, listeners: listeners, tasks: [
      { "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" },
      { "task_key" => "r1t0-model-1", "kind" => "model_task", "status" => "completed", "after" => %w[r1t0] },
      { "task_key" => "r2", "kind" => "model_task", "status" => "running", "after" => %w[r1t0-model-1] },
      { "task_key" => "r1", "kind" => "model_task", "status" => "waiting", "after" => %w[r1t0 r1t0-model-1 r2] },
    ]))

    follower = Thread.new { ops(:follow, "al-1") }
    handler = listeners.pop
    handler.call(Struct.new(:type, :payload).new("task_status",
      { "task_key" => "r2", "kind" => "model_task", "status" => "completed" }))
    state[:complete] = true
    handler.call(Struct.new(:type, :payload).new("task_status",
      { "task_key" => "r3", "kind" => "model_task", "status" => "running", "after" => %w[r2] }))

    assert follower.join(10), "follow never returned"
    out = @out.string
    assert_match(/^  completed      r1t0$/, out, out)
    assert_match(/^    completed      r1t0-model-1  \(r1t0\)$/, out, out)
    assert_match(/^    running        r2  \(r1t0\)$/, out, out)
    assert_match(/^  waiting        r1  waiting_on: r2$/, out, out)
    assert_match(/^    completed      r2  \(r1t0\)$/, out, "a pushed item renders the same way")
    assert_match(/^    running        r3  \(r1t0\)$/, out,
      "a frame that names only its parent still finds the call: `after` is remembered across frames")
  end

  TODO_THREE = [
    { "content" => "Add the CLI entry", "status" => "completed" },
    { "content" => "Parse the input file", "status" => "in_progress" },
    { "content" => "Write the tests", "status" => "pending" },
  ].freeze
  TODO_BLOCK = ["  todo       - [x] Add the CLI entry",
                "             - [>] Parse the input file",
                "             - [ ] Write the tests"].freeze

  # THE CHECKLIST ON THE PUSHED CHANNEL: the join-time snapshot prints the last `todo_write`'s list — one
  # task read through the daemon's member plane — and a pushed `progress`
  # frame that names a call followed by its `task_status completed` prints
  # the next one; nothing in the daemon, the kernel's row is the source.
  def test_follow_prints_the_todo_block_at_join_and_on_a_pushed_completion
    detail = { "kind" => "tool_task", "status" => "completed", "tool_name" => "todo_write",
               "tool_input" => { "todos" => TODO_THREE }, "output" => "Todo list updated: 3 items, 1 completed.",
               "result" => { "resolved" => true } }
    api = NexusDoubles::FakeAgentApi.new(task_detail: detail)
    daemon = boot(api: api)
    state = { complete: false }
    listeners = Queue.new
    member_hold_run(daemon, followed_run("al-1", state: state, listeners: listeners, tasks: [], snapshot: {
      public_id: "al-1", loop: "al-1",
      tasks: [{ "task_key" => "r1t0", "kind" => "tool_task", "status" => "completed" }],
      frames: [{ "seq" => 1, "type" => "step_started", "task_key" => "r1t0", "tool_name" => "todo_write",
                 "payload" => { "status" => "dispatched" } }],
    }))

    follower = Thread.new { ops(:follow, "al-1") }
    handler = listeners.pop
    handler.call(frame("progress", { "seq" => 2, "type" => "step_started", "agent_loop_public_id" => "al-1",
                                     "task_key" => "r2t0", "tool_name" => "todo_write", "at" => "2026-09-15T10:00:00Z",
                                     "payload" => { "status" => "dispatched" } }))
    handler.call(frame("task_status", { "task_key" => "r2t0", "kind" => "tool_task", "status" => "dispatched" }))
    state[:complete] = true
    handler.call(frame("task_status", { "task_key" => "r2t0", "kind" => "tool_task", "status" => "completed" }))

    assert follower.join(10), "follow never returned"
    lines = @out.string.lines.map(&:chomp)
    assert_equal ["  completed      r1t0", *TODO_BLOCK, "  dispatched     r2t0", "  completed      r2t0", *TODO_BLOCK,
                  "(stream ended: turn_settled)"], lines
    reads = api.requests.select { |path, _, _| path.match?(%r{/tasks/[^/]+\z}) }.map { |path, _, _| path[%r{/tasks/([^/]+)\z}, 1] }
    assert_equal %w[r1t0 r2t0], reads, "one kernel read per change"
  end

  # THE THREAD from a terminal: each round's calls print ABOVE its
  # words (they happened first), then what the fan withheld, then the
  # branches `--prefix` expands; a branch's own rows say `(branch)` and
  # `--prefix` is a page, printed the same way.
  def test_transcript_prints_the_calls_above_the_text_the_overflow_and_the_branches_and_a_prefix_expands_one
    spine = { "transcript" => {
      "rounds" => [
        { "task_key" => "r1", "spine" => true, "status" => "completed", "visibility" => "visible",
          "text_preview" => "I will read the file.", "calls" => { "count" => 0, "items" => [] }, "branches" => [] },
        { "task_key" => "r2", "spine" => true, "status" => "completed", "visibility" => "visible",
          "text_preview" => "The review found one unused method.",
          "usage" => { "total_tokens" => 1222 },
          "calls" => { "count" => 27, "items" => [
            { "task_key" => "r2t0", "name" => "read_file", "status" => "completed", "title" => "read x.rb",
              "output_preview" => "class Foo" },
            { "task_key" => "r2t1", "name" => "Agent", "tool" => "task", "status" => "completed", "is_error" => false },
          ] },
          "branches" => %w[r2t1] },
      ],
      "next_before" => "MQ", "has_older" => true,
    } }
    branch = { "transcript" => {
      "rounds" => [
        { "task_key" => "r2t1-model-1", "spine" => false, "status" => "completed", "visibility" => "visible",
          "text_preview" => "Reading lib/x.rb.", "calls" => { "count" => 0, "items" => [] }, "branches" => [] },
        { "task_key" => "r3", "spine" => false, "status" => "completed", "visibility" => "visible",
          "text_preview" => "lib/x.rb — orphan",
          "calls" => { "count" => 1, "items" => [{ "task_key" => "r3t0", "name" => "read_file", "status" => "completed" }] },
          "branches" => [] },
      ],
      "next_before" => nil, "has_older" => false,
    } }
    # The table matches by prefix of the request line, so the spine's key
    # ends at the request's own space.
    announce(endpoint: routed_endpoint(
      "GET /loops/transcript?public_id=al-9 " => [[200, spine]],
      "GET /loops/transcript?public_id=al-9&prefix=r2t1" => [[200, branch]],
      "GET /loops/transcript?public_id=al-9&prefix=r2t0" => [[200, { "transcript" => { "rounds" => [], "has_older" => false } }]]
    ))

    ops(:transcript, "al-9")
    assert_equal [
      "r1  completed",
      "  I will read the file.",
      "r2  completed  27 calls  1222t",
      "  - read_file completed — read x.rb",
      "    class Foo",
      "  - Agent completed",
      "  … 25 more calls",
      "  +1 branch under r2t1",
      "  The review found one unused method.",
      "older:     MQ",
    ], @out.string.lines.map(&:chomp)

    @out.truncate(0)
    @out.rewind
    ops(:transcript, "al-9", prefix: "r2t1")
    assert_equal [
      "r2t1-model-1 (branch)  completed",
      "  Reading lib/x.rb.",
      "r3 (branch)  completed  1 call",
      "  - read_file completed",
      "  lib/x.rb — orphan",
    ], @out.string.lines.map(&:chomp)

    @out.truncate(0)
    @out.rewind
    ops(:transcript, "al-9", prefix: "r2t0")
    assert_equal "(nothing under r2t0)\n", @out.string, "an ask's or a plain call's expansion is honestly empty"
  end

  # THE FOLD ON THE CLI: `--follow` prints the page, then folds
  # the daemon's stream through the SDK's ThreadAccumulator — a kernel
  # frame moves the `live` line, a settled `call` lands under the round
  # its number names, a settled spine `round` prints whole when it
  # settles, a branch's round never prints — and ends with the stream.
  def test_transcript_follow_folds_the_stream_after_the_page_and_ends_with_the_loop
    page = { "rounds" => [
      { "task_key" => "r1", "spine" => true, "status" => "completed", "visibility" => "visible",
        "text_preview" => "I will read the file.", "calls" => { "count" => 0, "items" => [] }, "branches" => [] },
    ], "pagination" => { "next_before" => nil, "has_older" => false } }
    daemon = boot(api: NexusDoubles::FakeAgentApi.new(transcript: page))
    state = { complete: false }
    listeners = Queue.new
    member_hold_run(daemon, followed_run("al-1", tasks: [], state: state, listeners: listeners))

    follower = Thread.new { ops(:transcript, "al-1", follow: true) }
    handler = listeners.pop
    handler.call(frame("progress", { "seq" => 1, "type" => "step_started", "agent_loop_public_id" => "al-1",
                                     "task_key" => "r2t0", "tool_name" => "read_file", "at" => "2026-09-14T10:00:00.250Z",
                                     "payload" => { "status" => "dispatched" } }))
    handler.call(frame("progress", { "seq" => 2, "type" => "round_started", "agent_loop_public_id" => "other-loop",
                                     "task_key" => "r9", "at" => "2026-09-14T10:00:00.250Z",
                                     "payload" => { "spine" => true, "attempt" => 1, "model" => "dev/mock-text", "request_bytes" => 8 } }))
    handler.call(frame("call", { "type" => "call", "agent_loop_public_id" => "al-1", "task_key" => "r2t0",
                                 "payload" => { "call" => { "task_key" => "r2t0", "name" => "read_file", "status" => "completed",
                                                            "output_preview" => "class Foo" } } }))
    handler.call(frame("round", { "type" => "round", "agent_loop_public_id" => "al-1", "task_key" => "r3",
                                  "payload" => { "round" => { "task_key" => "r3", "spine" => false, "status" => "completed",
                                                              "visibility" => "visible", "text_preview" => "a branch's own round",
                                                              "calls" => { "count" => 0, "items" => [] }, "branches" => [] } } }))
    handler.call(frame("progress", { "seq" => 3, "type" => "round_started", "agent_loop_public_id" => "al-1",
                                     "task_key" => "r2", "at" => "2026-09-14T10:00:00.250Z",
                                     "payload" => { "spine" => true, "attempt" => 1, "model" => "dev/mock-text", "request_bytes" => 41_208 } }))
    state[:complete] = true
    handler.call(frame("round", { "type" => "round", "agent_loop_public_id" => "al-1", "task_key" => "r2",
                                  "payload" => { "round" => { "task_key" => "r2", "spine" => true, "status" => "completed",
                                                              "visibility" => "visible", "text_preview" => "class Foo has one method.",
                                                              "calls" => { "count" => 1, "items" => [{ "task_key" => "r2t0", "name" => "read_file",
                                                                                                        "status" => "completed", "output_preview" => "class Foo" }] },
                                                              "branches" => [] } } }))

    assert follower.join(10), "the follow never returned"
    assert_equal [
      "r1  completed",
      "  I will read the file.",
      "live:      r2t0",
      "live:      (nothing)",
      "live:      r2",
      "r2  completed  1 call",
      "  - read_file completed",
      "    class Foo",
      "  class Foo has one method.",
      "live:      (nothing)",
      "(stream ended: turn_settled)",
    ], @out.string.lines.map(&:chomp), "another loop's frame and a branch's round print nothing"
  end

  def test_transcript_refuses_to_follow_a_prefix
    error = assert_raises(Rho::Error) { ops(:transcript, "al-1", follow: true, prefix: "r2t0") }

    assert_match(/--follow follows the spine and --prefix is a page/, error.message)
  end

  def test_phases_prints_one_line_per_phase_and_marks_the_current_one
    announce(endpoint: routed_endpoint(
      "GET /loops/phases?public_id=al-9" => [[200, { "phases" => {
        "phases" => [
          { "label" => "tests · lint", "keys" => %w[tests lint], "done" => 2, "total" => 2, "status" => "completed" },
          { "label" => "summary", "keys" => ["summary"], "done" => 0, "total" => 1, "status" => "running" },
        ],
        "current" => 1,
        "background" => [
          { "key" => "r1t0-model-1", "status" => "running" },
          { "key" => "r1t0-model-2", "status" => "completed", "mailed_at" => "2026-09-06T00:00:09.000Z" },
        ],
        "spend" => { "input_tokens" => 41, "output_tokens" => 6, "cost_amount" => "0.5", "cost_unit" => "USD" },
      } }]]
    ))

    ops(:phases, "al-9")

    lines = @out.string.lines.map(&:chomp)
    assert_equal "  tests · lint  2/2  completed", lines[0]
    assert_equal "> summary  0/1  running", lines[1]
    assert_equal "background: r1t0-model-1 running", lines[2]
    assert_equal "background: r1t0-model-2 completed  (mailed 2026-09-06T00:00:09.000Z)", lines[3],
      "a tip the kernel delivered as mail says when"
    assert_equal "spend:     41 in, 6 out — 0.5 USD", lines[4]
  end

  # A loop a step of which re-ran on another model — the declared fallback
  # after a refusal — says whose spend was whose, one line per model under
  # the sum; a one-model loop prints the sum alone.
  def test_phases_splits_the_spend_by_model_when_more_than_one_ran
    by_model = {
      "dev/primary" => { "input_tokens" => 30, "output_tokens" => 0, "cost_amount" => "0.3",
                                       "cost_unit" => "USD" },
      "dev/fallback" => { "input_tokens" => 11, "output_tokens" => 6, "cost_amount" => nil,
                                  "cost_unit" => nil },
    }
    announce(endpoint: routed_endpoint(
      "GET /loops/phases?public_id=al-9" => [[200, { "phases" => {
        "phases" => [], "current" => nil, "background" => [],
        "spend" => { "input_tokens" => 41, "output_tokens" => 6, "cost_amount" => "0.3", "cost_unit" => "USD",
                     "by_model" => by_model },
      } }]]
    ))

    ops(:phases, "al-9")

    assert_equal ["(no phases yet)", "spend:     41 in, 6 out — 0.3 USD",
                  "  dev/primary  30 in, 0 out — 0.3 USD",
                  "  dev/fallback  11 in, 6 out"],
      @out.string.lines.map(&:chomp)
  end

  # The picture from a terminal: Mermaid by default — the text a person
  # pastes into a renderer — and the JSON behind it on request.
  def test_graph_prints_the_mermaid_text_by_default_and_the_json_on_request
    picture = {
      "nodes" => [{ "key" => "r1", "kind" => "model_task", "status" => "completed",
                    "visibility" => "visible", "deliverable" => true }],
      "edges" => [],
      "mermaid" => "flowchart TD\n  n0[[\"r1 · model_task · completed\"]]:::completed",
    }
    announce(endpoint: routed_endpoint(
      "GET /loops/graph?public_id=al-9" => [[200, { "graph" => picture }]]
    ))

    printed = ops(:graph, "al-9")
    assert_equal picture, printed
    assert_equal "#{picture.fetch("mermaid")}\n", @out.string

    @out.truncate(0)
    @out.rewind
    ops(:graph, "al-9", json: true)
    assert_equal picture, JSON.parse(@out.string)
  end

  def test_graph_carries_the_daemon_s_refusal
    announce(endpoint: routed_endpoint(
      "GET /loops/graph?public_id=al-9" => [[404, { "error" => { "code" => "not_found", "message" => "no such loop" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:graph, "al-9") }
    assert_includes error.message, "no such loop"
  end
end
