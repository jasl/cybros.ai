require "support/runner_loop_fixtures"

class RunnerLoopTest < Minitest::Test
  include RunnerLoopFixtures


  def test_a_nudge_claims_that_one_task_and_never_lists
    lane = Lane.new(rows: [row("t1")])
    subject = runner(lane)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal ["t1"], lane.claims, "claiming IS the fetch"
    assert_equal 1, lane.commits.length
    submitted = lane.commits.first
    assert_equal "tok-t1", submitted.fetch(:claim_token)
    assert_equal "completed", submitted.fetch(:outcome)
    assert_equal "echo: hi", submitted.fetch(:content)
  end

  # A ROW ADDRESSED HERE IS ONE THIS ADDRESS ANNOUNCED:
  # nexus addresses work by the announcement, so there is no local "is
  # this mine?" gate and no decline path. A name the toolset no longer
  # holds — an announcement drift under a frozen addressee — is claimed
  # and answered `failed` with a readable detail, never left claimed to
  # its park deadline where no runner can reach it.
  def test_a_row_addressed_here_for_a_tool_this_runner_no_longer_holds_is_claimed_and_answered_failed
    lane = Lane.new(rows: [row("t1", tool: "compile_kernel")])
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: Silent.new, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done,
      subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "compile_kernel")

    assert_equal ["t1"], lane.claims, "addressed here means announced here: it is taken"
    submitted = only(lane.commits)
    assert_equal "failed", submitted[:outcome], "could not run at all — the loop's policy decides now"
    refute submitted.key?(:is_error), "failed is control; is_error is data"
    assert_includes submitted[:content], "no longer serves \"compile_kernel\""
    refute_includes submitted[:content], "KeyError", "a detail a weak model can act on, not a Ruby class"
    refute_nil pool.reserve, "the ticket was not returned"
  ensure
    pool&.stop
  end

  # A refused claim is ORDINARY — another runner won — and must not be an
  # error path, a backoff, or a warning.
  def test_losing_a_claim_is_ordinary
    lane = Lane.new(rows: [row("t1")], grant: :taken)
    subject = runner(lane)
    assert_equal :skipped,
      subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_empty lane.commits
  end

  # THE FIRST AXIS: the tool RAN and returned an error. That is DATA the model
  # reads and self-corrects from, so the task COMPLETED.
  def test_a_tool_that_ran_and_errored_completes_with_is_error
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| Rho::Runner::Result.error("no such file") }
    subject = runner(lane, tools)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal 1, lane.commits.length
    submitted = lane.commits.first
    assert_equal "completed", submitted.fetch(:outcome)
    assert_equal true, submitted.fetch(:is_error)
    assert_equal "no such file", submitted.fetch(:content)
  end

  # THE SECOND AXIS: the tool could not run AT ALL. Only a raise becomes
  # `failed`, which takes the task's own failure policy.
  def test_a_tool_that_could_not_run_fails
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| raise Errno::ENOENT, "rg" }
    subject = runner(lane, tools)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal 1, lane.commits.length
    submitted = lane.commits.first
    assert_equal "failed", submitted.fetch(:outcome)
    refute submitted.key?(:is_error), "failed is control; is_error is data"
    assert_includes submitted.fetch(:content), "Errno::ENOENT"
  end

  # THE INBOX IS THE TRUTH: a runner that missed every frame recovers by
  # listing. A claimed row is listed too — a runner returning from a crash
  # must see the work it holds — and left alone.
  def test_the_sweep_recovers_work_the_cable_never_announced
    lane = Lane.new(rows: [row("t1"), row("t2", claimed: true), row("t3")])
    subject = runner(lane)
    subject.send(:sweep)
    subject.stop

    assert_equal %w[t1 t3], lane.claims, "somebody else's row is not taken"
    assert_equal %w[t1 t3], lane.commits.map { |s| s.fetch(:claim_token).delete_prefix("tok-") }
  end

  # AN ASK IS THE AGENT'S ROW, NOT THE RUNNER'S: it lists on
  # the same inbox — listed for its addressee, never claimed — and the
  # sweep leaves it alone rather than taking it and being refused
  # `not_claimable_kind` every five seconds. A kind this runner does not
  # know is carried the same way: left, never taken.
  def test_an_ask_row_on_the_page_is_left_to_the_agent
    ask = Task.new(workspace_public_id: "ws-1", kind: "ask", agent_loop_public_id: "loop-1", task_key: "a1", tool_name: nil,
      prompt: "which database?", tool_input: {}, tool_call_id: nil, started_at: nil,
      deadline_at: nil, timeout_ms: nil, claimed: false,
      addressed_to: CybrosAgent::Api::AddressedTo.new(role: "agent_application", executor_public_id: "ex-1"))
    unknown = Task.new(workspace_public_id: "ws-1", kind: "approval", agent_loop_public_id: "loop-1", task_key: "p1", tool_name: nil,
      tool_input: {}, tool_call_id: nil, started_at: nil, deadline_at: nil, timeout_ms: nil, claimed: false,
      addressed_to: CybrosAgent::Api::AddressedTo.new(role: "runner", executor_public_id: "ex-1"))
    lane = Lane.new(rows: [ask, row("t1"), unknown])
    log = Kept.new
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: log,
      pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil })
    subject.send(:sweep)
    subject.stop

    assert_equal ["t1"], lane.claims, "only the tool row is the runner's to take"
    assert_equal 1, subject.snapshot.claimed
    assert_empty log.warned.select { |event, _| event == "runner_task_failed" }
  end

  def test_successive_sweeps_pass_claimed_and_human_held_rows_then_wrap_to_the_first_page
    held = Array.new(Rho::Runner::PAGE_LIMIT) do |i|
      case i % 3
      when 0 then row("held-#{i}", claimed: true)
      when 1 then row("held-#{i}").with(kind: "ask")
      else row("held-#{i}").with(kind: "approval")
      end
    end
    waiting = row("waiting")
    lane = Lane.new(rows: [*held, waiting], pages: {
      nil => Page.new(items: held, next_after: "next-page"),
      "next-page" => Page.new(items: [waiting], next_after: nil),
    })
    subject = runner(lane)

    subject.send(:sweep)
    assert_equal 1, lane.lists, "one pass reads only one page"
    assert_empty lane.claims
    subject.send(:sweep)
    assert_equal ["waiting"], lane.claims, "held rows must not hide work on the next page"
    assert_equal ["completed"], lane.commits.map { |commit| commit.fetch(:outcome) }
    subject.send(:sweep)
    assert_equal [nil, "next-page", nil], lane.list_cursors, "a finished scan restarts at the first page"
  ensure
    subject&.stop
  end

  def test_an_empty_page_with_a_cursor_advances_on_the_next_sweep
    waiting = row("waiting")
    lane = Lane.new(rows: [waiting], pages: {
      nil => Page.new(items: [], next_after: "next-page"),
      "next-page" => Page.new(items: [waiting], next_after: nil),
    })
    subject = runner(lane)

    subject.send(:sweep)
    assert_equal 1, lane.lists
    assert_empty lane.claims
    subject.send(:sweep)
    assert_equal ["waiting"], lane.claims
  ensure
    subject&.stop
  end

  def test_a_failed_inbox_read_retries_the_same_page_on_the_next_sweep
    waiting = row("waiting")
    reads = 0
    lane = Lane.new(rows: [waiting], pages: {
      nil => Page.new(items: [], next_after: "next-page"),
      "next-page" => Page.new(items: [waiting], next_after: nil),
    }, on_list: lambda {
      reads += 1
      raise CybrosAgent::Api::ServerError, "temporarily unavailable" if reads == 2
    })
    subject = runner(lane)

    3.times { subject.send(:sweep) }
    assert_equal [nil, "next-page", "next-page"], lane.list_cursors
    assert_equal ["waiting"], lane.claims
    assert_equal 1, lane.commits.length
  ensure
    subject&.stop
  end

  # A tool's structured half rides its OWN field now. It used to be
  # wrapped into `metadata` — the UI channel the model never sees — which
  # made a structured result structured for everyone except its reader.
  def test_structured_content_rides_its_own_field_not_the_ui_channel
    lane = Lane.new(rows: [row("t1")])
    tools = toolset do |_args, _ctx|
      Rho::Runner::Result.ok("2 matches", { "count" => 2 }, title: "grep foo")
    end
    subject = runner(lane, tools)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal 1, lane.commits.length
    submitted = lane.commits.first
    assert_equal "grep foo", submitted.fetch(:title)
    assert_equal({ "count" => 2 }, submitted.fetch(:structured_content))
    refute submitted.key?(:metadata), "the UI channel carries UI material and nothing else"
    assert_equal "2 matches", submitted.fetch(:content)
  end

  # THE MODEL-INVISIBLE CARRIER (executor.md's one reserved key): a tool that answers `metadata` — the checkpoint key on the first
  # write-kind result, the undo on a restore — sees it committed AS IT
  # LEFT IT, beside the text and the structure; a tool that answers none
  # commits no `metadata` field at all.
  def test_metadata_rides_the_commit_as_the_tool_left_it_and_is_absent_when_none
    lane = Lane.new(rows: [row("t1"), row("t2", input: { "metadata" => true })])
    key = { "checkpoint" => { "hash" => "a" * 40, "store" => "0123456789abcdef", "outside" => ["/x"] } }
    tools = toolset do |args, _ctx|
      if args["metadata"]
        Rho::Runner::Result.ok("restored", { "undo" => "b" * 40 }, title: "world restored", metadata: key)
      else
        Rho::Runner::Result.ok("plain")
      end
    end
    subject = runner(lane, tools)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t2", tool_name: "echo")
    subject.stop

    assert_equal 2, lane.commits.length
    with_key = lane.commits.find { |fields| fields[:content] == "restored" }
    plain = lane.commits.find { |fields| fields[:content] == "plain" }
    assert_equal key, with_key.fetch(:metadata), "verbatim: the runner's own record, never bounded or reshaped"
    assert_equal({ "undo" => "b" * 40 }, with_key.fetch(:structured_content))
    assert_equal "world restored", with_key.fetch(:title)
    refute plain.key?(:metadata), "no carrier when the tool answered none"
  end

  # THE KEY RIDES THROUGH THE RUN ITSELF: the real Coding set beside the checkpoints
  # extension on a real store, driven through `TaskRun#run_handler` as the daemon drives
  # it — the `tool_call` chain on the worker captures under the row's loop, and the
  # `tool_result` chain, which runs on the reactor after the pool returns, reads the SAME
  # loop off `ExecutionContext.current` to attach the key. The extension's own unit binds
  # the context by hand around both chains; this pin is the run's binding, where a first
  # cut left the result chain unbound and every key on the floor.
  def test_the_checkpoint_key_rides_the_commit_through_the_run
    Dir.mktmpdir("rho-runner-ride") do |tmp|
      root = File.join(tmp, "root")
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib", "a.rb"), "one")
      store = Rho::Runner::Checkpoints::Store.open(dir: File.join(tmp, "checkpoints"), root: root)
      loaded = Rho::Runner::Extensions::Loader.call(
        builtin: [Rho::Runner::Extensions::Coding, Rho::Runner::Extensions::Checkpoints],
        api_options: { host: Data.define(:checkpoints, :processes).new(checkpoints: store, processes: nil) }
      )
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(tmp, "artifacts"), checkpoints: store)
      lane = Lane.new(rows: [
        row("t1", tool: "read", input: { "path" => "lib/a.rb" }),
        row("t2", tool: "write", input: { "path" => "lib/a.rb", "content" => "two" }),
        row("t3", tool: "write", input: { "path" => "lib/b.rb", "content" => "three" }),
      ])
      pool = Rho::Runner::Pool.new(worker_threads: 2)
      subject = Rho::Runner.new(executor: lane, toolsets: fixed(loaded.registry.toolset(env: env)), log: Silent.new,
        pool: pool, sleeper: ->(_) { nil }, hooks: loaded.registry.hooks)
      %w[t1 t2 t3].each { |key| subject.nudged(agent_loop_public_id: "loop-1", task_key: key) }
      subject.stop

      record = store.records(loop: "loop-1").first
      refute_nil record, "the first write captured under the row's loop"
      by_key = lane.commits.to_h { |fields| [fields.fetch(:claim_token), fields] }
      refute by_key.fetch("tok-t1").key?(:metadata), "a read rides nothing"
      assert_equal({ "checkpoint" => { "hash" => record.hash, "store" => store.id } },
        by_key.fetch("tok-t2").fetch(:metadata), "the first write-kind result carries the key")
      refute by_key.fetch("tok-t3").key?(:metadata), "the second write rides nothing"
      assert_equal 1, store.records.length, "one capture per loop"
    ensure
      pool&.stop
    end
  end

  # A saturated runner does not claim: it leaves the row for a sibling, and
  # the level-triggered inbox is the retry.
  # A HANDLER RAISING ANYTHING AT ALL IS THAT TASK'S PROBLEM. The pool
  # already wrote that rule down and rescues Exception for it; this frame
  # took only StandardError, so a plugin's badly-declared error escaped
  # `take` (CybrosAgent::Error only), escaped `sweep` (StandardError only),
  # and ended `follow` — the runner stopped claiming ANY work while the
  # task it held sat claimed-and-unanswerable until its deadline.
  class Boom < Exception; end # rubocop:disable Lint/InheritException

  def test_a_tool_raising_outside_standard_error_fails_its_task_and_the_runner_lives
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| raise Boom, "declared wrong" }
    subject = runner(lane, tools)

    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "failed", submitted[:outcome], "the claim is answered, not held"
    assert_includes submitted[:content], "Boom"

    # AND THE LOOP SURVIVES IT. One extension's mistake must not stop a
    # daemon from claiming work — nobody is watching a home server.
    lane2 = Lane.new(rows: [row("t2")])
    ok = Rho::Runner.new(executor: lane2, toolsets: fixed(toolset), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil })
    ok.nudged(agent_loop_public_id: "loop-1", task_key: "t2")
    assert_equal "completed", only(lane2.commits)[:outcome]
  end

  # THE MACHINE AND THE OPERATOR STILL GET THROUGH. Swallowing a shutdown
  # or an exhausted machine into a task failure would be a lie about why
  # the work stopped — but the claim is released first either way.
  def test_a_process_fatal_condition_answers_the_claim_then_propagates
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| raise NoMemoryError, "out of memory" }
    subject = runner(lane, tools)

    assert_raises(NoMemoryError) do
      subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1")
    end
    assert_equal "failed", only(lane.commits)[:outcome],
      "answered before it propagated — a held claim parks to its deadline"
  end

  # THE WORK IS DONE, PAID FOR, AND THROWN AWAY. Nexus measures the
  # serialized result against snapshot_bound and refuses over it AFTER the
  # tool has run; `answer` logs runner_submit_refused and DROPS the answer.
  # Nothing capped it on this side, so an oversized result was simply lost.
  def test_an_oversized_result_is_truncated_rather_than_refused_and_lost
    lane = Lane.new(rows: [row("t1")])
    huge = "x" * (2 * 1024 * 1024)
    tools = toolset { |_args, _ctx| Rho::Runner::Result.ok(huge) }

    runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    assert_operator JSON.generate(submitted[:content]).bytesize, :<,
      Rho::Runner::TaskRun::SUBMIT_BOUND_BYTES,
      "what goes on the wire must fit the bound the server measures"
    assert submitted[:content].end_with?("[result truncated to fit the server's size bound]"),
      "a silent truncation reads as a complete answer"
    assert submitted[:content].start_with?("x"), "the TAIL is kept, as every tool here keeps it"
  end

  # THE TEXT WINS. `content` is what the model reads and self-corrects on;
  # structured content is the client's half. When only one fits, keeping
  # the model's half leaves the round able to continue — and saying so
  # beats a client seeing typed data that is simply absent.
  def test_oversized_structured_content_yields_to_the_text
    lane = Lane.new(rows: [row("t1")])
    tools = toolset do |_args, _ctx|
      Rho::Runner::Result.ok("the answer", { "paths" => ["y" * 2 * 1024 * 1024] })
    end

    runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    refute submitted.key?(:structured_content), "it yielded"
    assert submitted[:content].start_with?("the answer"), "the model's half survived intact"
    assert_includes submitted[:content], "structured content omitted"
  end

  # THE ONE UPLOAD SITE: a tool names its captures as
  # paths; the run stages each on the executor plane AFTER the handler
  # returned and commits `content` as the text block, then one
  # `resource_link` per capture — the name, the server's type and size.
  def test_a_result_naming_files_is_uploaded_after_the_handler_and_linked_beside_the_text
    Dir.mktmpdir("rho-runner-capture") do |dir|
      shot = File.join(dir, "browser-1.png")
      File.binwrite(shot, "\x89PNG" + ("x" * 12))
      order = []
      lane = Lane.new(rows: [row("t1")], on_upload: ->(_path) { order << :upload })
      tools = toolset do |_args, _ctx|
        order << :handler
        Rho::Runner::Result.ok("Saved a screenshot to #{shot}", files: [shot])
      end

      runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

      assert_equal %i[handler upload], order, "the handler returns first; the upload is the run's"
      assert_equal [shot], lane.uploaded
      submitted = only(lane.commits)
      assert_equal [
        { "type" => "text", "text" => "Saved a screenshot to #{shot}" },
        { "type" => "resource_link", "uri" => "nexus://uploads/up-1", "name" => "browser-1.png",
          "mimeType" => "image/png", "size" => 16 },
      ], submitted.fetch(:content)
      refute submitted.key?(:metadata)
    end
  end

  # A capture the door refuses costs the LINK, never the answer: the text
  # half — which already names the path on this runner — commits as a
  # String, the refusal is logged once, and a file that vanished between
  # the handler and the upload is the same case.
  def test_a_refused_or_vanished_capture_drops_its_link_and_the_text_still_commits
    Dir.mktmpdir("rho-runner-capture") do |dir|
      big = File.join(dir, "big.log")
      File.write(big, "x" * 8)
      log = Kept.new
      gone = File.join(dir, "gone.log")
      lane = Lane.new(rows: [row("t1", input: { "text" => big })], on_upload: lambda { |path|
        raise CybrosAgent::Api::InvalidRequest.new("too large", code: "content_too_large") if path == big
      })
      tools = toolset do |args, _ctx|
        Rho::Runner::Result.ok("Full output: #{args["text"]}", files: [args["text"]])
      end
      Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: log,
        pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil })
        .nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
      lane2 = Lane.new(rows: [row("t2", input: { "text" => gone })])
      Rho::Runner.new(executor: lane2, toolsets: fixed(tools), log: log,
        pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil })
        .nudged(agent_loop_public_id: "loop-1", task_key: "t2", tool_name: "echo")

      assert_equal "Full output: #{big}", only(lane.commits).fetch(:content), "the door refused: the text alone, a String"
      assert_equal "Full output: #{gone}", only(lane2.commits).fetch(:content), "the file vanished: the same"
      refused = log.warned.select { |event, _| event == "runner_capture_refused" }.map(&:last)
      assert_equal [[big, "content_too_large"], [gone, "Errno::ENOENT"]],
        refused.map { |fields| [fields.fetch(:path), fields.fetch(:code)] }, log.warned.inspect
    end
  end

  def test_a_required_publication_refusal_is_an_error_without_a_download_link
    Dir.mktmpdir("rho-runner-publication") do |dir|
      path = File.join(dir, "report.pdf")
      File.write(path, "%PDF-report")
      lane = Lane.new(rows: [row("t1")], on_upload: lambda { |_path|
        raise CybrosAgent::Api::InvalidRequest.new("too large", code: "content_too_large")
      })
      tools = toolset do |_args, _ctx|
        Rho::Runner::Result.ok("selected for publication", files: [path], files_required: true)
      end
      runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")
      result = only(lane.commits)
      assert result.fetch(:is_error)
      assert_equal "completed", result.fetch(:outcome)
      assert_equal "File publication failed; no downloadable artifact was produced.", result.fetch(:content)
    end
  end

  def test_a_result_inside_the_bound_is_submitted_untouched
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| Rho::Runner::Result.ok("small", { "n" => 1 }) }

    runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "small", submitted[:content]
    assert_equal({ "n" => 1 }, submitted[:structured_content])
  end

  # THE RUNNER OWNS THE BYTES: PostgreSQL stores no U+0000, so the kernel refuses a result
  # carrying one (`result_unstorable`) — after the tool has run — and the answer was
  # dropped, the park left to its deadline. A NUL in a tool's text is a fact about the
  # output (a binary `cat`, a `find -print0`), so it is written as its JSON escape
  # `\u0000` — the six characters, which say exactly which byte stood there, where the
  # replacement character would read as the scrub's "invalid bytes" — and the substitution
  # is stated once at the end of the text. Every string of the answer: the text, the
  # failed branch's message, and the strings inside `structured_content`, which the kernel
  # stores through the same door.
  def test_a_nul_byte_in_the_result_is_escaped_before_the_submit_and_said_once
    lane = Lane.new(rows: [row("t1")])
    tools = toolset { |_args, _ctx| Rho::Runner::Result.ok("a\u0000b\u0000", { "raw" => "x\u0000y", "n" => 1 }) }

    runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    assert_equal "a\\u0000b\\u0000#{Rho::Runner::StorableText::NOTE}", submitted[:content]
    assert_equal({ "raw" => "x\\u0000y", "n" => 1 }, submitted[:structured_content])
    refute_includes JSON.generate(submitted), "\u0000", "nothing unstorable goes on the wire"
  end

  def test_a_nul_byte_in_a_failed_tools_message_is_escaped_too
    lane = Lane.new(rows: [row("t1")])
    # A plain raise: Errno::ENOENT refuses a NUL in its own message (ArgumentError).
    tools = toolset { |_args, _ctx| raise "rg\u0000 vanished" }
    subject = runner(lane, tools)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    submitted = only(lane.commits)
    assert_equal "failed", submitted[:outcome]
    refute_includes submitted[:content], "\u0000"
    assert_includes submitted[:content], "rg\\u0000"
    assert submitted[:content].end_with?(Rho::Runner::StorableText::NOTE)
  end

  # The bound is measured on the SUBMITTED bytes: the escape grows one
  # byte into six, so a text that fit before the substitution is truncated
  # after it, never refused by the server's measure.
  def test_the_bound_is_measured_after_the_escape
    lane = Lane.new(rows: [row("t1")])
    nuls = "\u0000" * (Rho::Runner::TaskRun::SUBMIT_BOUND_BYTES / 4)
    tools = toolset { |_args, _ctx| Rho::Runner::Result.ok(nuls) }

    runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_operator JSON.generate(submitted[:content]).bytesize, :<, Rho::Runner::TaskRun::SUBMIT_BOUND_BYTES
    refute_includes submitted[:content], "\u0000"
    assert submitted[:content].end_with?("[result truncated to fit the server's size bound]")
  end

  # The real thing: a command printing a NUL byte, through the bash tool
  # and the runner's door, submits — and what it submits is storable.
  def test_a_command_printing_a_nul_byte_submits_a_storable_answer
    lane = Lane.new(rows: [row("t1")])
    RunnerTest::Helpers.instance_method(:with_tool_env).bind_call(self) do |env, _root|
      tools = toolset { |_args, _ctx| Rho::Runner::Tools::Bash.new(env:).call({ "command" => "printf 'a\\0b'" }) }

      runner(lane, tools).nudged(agent_loop_public_id: "loop-1", task_key: "t1")
    end

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    assert submitted[:content].start_with?("a\\u0000b"), submitted[:content]
    refute_includes JSON.generate(submitted), "\u0000"
  end

  # THE HOOKS, THROUGH THE REAL PATH. A gate tested only in isolation is a
  # gate nobody has proven is reachable.
  def hooked(lane, *registrations)
    Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 2), sleeper: ->(_) { nil },
      hooks: Rho::Runner::Extensions::Hooks::Host.new(registrations))
  end

  def registration(event, extension = "rho.guard", &handler)
    Rho::Runner::Extensions::Hooks::Registration.new(
      event: event, extension: extension, handler: handler
    )
  end

  # A VETO IS DATA. It answers `completed` with `is_error: true`, so the
  # model reads why it was refused and corrects itself — where failing the
  # task would take the round's failure policy and tell it nothing.
  def test_a_vetoed_call_answers_the_model_instead_of_failing_the_task
    lane = Lane.new(rows: [row("t1")])
    guard = registration(:tool_call) do |_name, _args|
      Rho::Runner::Extensions::Hooks::Veto.new(extension: "rho.guard", reason: "not allowed here")
    end

    hooked(lane, guard).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome], "a refusal the model can act on, not a dead task"
    assert submitted[:is_error]
    assert_includes submitted[:content], "blocked by rho.guard: not allowed here"
  end

  # WHOSE WORK IT IS reaches the handler through the context bound on the
  # worker thread — the only place a tool that holds a resource across
  # calls (a browser tab) can learn which loop's calls belong together.
  def test_the_handler_sees_which_loop_and_task_it_is_running_for
    lane = Lane.new(rows: [row("t1")])
    whoami = toolset do |_args, _ctx|
      context = Rho::Runner::ExecutionContext.current
      Rho::Runner::Result.ok("#{context.agent_loop_public_id}/#{context.task_key}")
    end

    runner(lane, whoami).nudged(agent_loop_public_id: "loop-1", task_key: "t1")

    assert_equal "loop-1/t1", only(lane.commits)[:content]
  end

  # THE KERNEL'S SCOPE STAMP reaches the handler the same way:
  # a row whose name is an overridden kernel canonical carries
  # `{workspace_public_id, conversation_public_id, user_public_id}`, and a
  # provider serving memory keys its store by it — never by guessing from
  # `tool_input`. Every other row, and a context built outside a task,
  # answers nil.
  def test_the_handler_sees_the_kernel_scope_stamp_on_an_overridden_row_and_nil_elsewhere
    stamp = { "workspace_public_id" => "ws-1", "conversation_public_id" => nil, "user_public_id" => "hu-1" }.freeze
    lane = Lane.new(rows: [row("t1", tool: "memory_read", scope: stamp), row("t2")])
    seen = {}
    scoped = Rho::Runner::Toolset.new(
      %w[memory_read echo].to_h do |name|
        [name, Rho::Runner::Toolset::Tool.new(
          name: name, description: name, parameters: { "type" => "object" },
          handler: lambda do |_args, _ctx|
            seen[name] = Rho::Runner::ExecutionContext.current.scope
            Rho::Runner::Result.ok(name)
          end
        )]
      end
    )

    subject = runner(lane, scoped)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1")
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t2")

    assert_equal stamp, seen.fetch("memory_read"), "the stamp rode the claim into the handler's context"
    assert_predicate seen.fetch("memory_read"), :frozen?
    assert_nil seen.fetch("echo"), "a runner row carries no stamp"
    assert_nil Rho::Runner::ExecutionContext.new.scope, "outside a task there is nothing to stamp"
  end

  # EVERY ROW NAMES ITS CONVERSATION (the process lifecycle follows the conversation): the handler's context carries the kernel's
  # word — the loop's conversation, nil for a standalone loop — so a tool
  # that holds something across calls owns it by the conversation and
  # never resolves the loop itself.
  def test_the_handler_sees_the_rows_conversation_and_nil_for_a_standalone_loop
    lane = Lane.new(rows: [row("t1", conversation: "conv-1"), row("t2")])
    seen = {}
    subject = runner(lane, toolset do |_args, ctx|
      seen[ctx.task_key] = ctx.conversation_public_id
      Rho::Runner::Result.ok("seen")
    end)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1")
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t2")

    assert_equal "conv-1", seen.fetch("t1"), "the row's conversation rode the claim into the context"
    assert_nil seen.fetch("t2"), "a standalone loop's row names none"
    assert_nil Rho::Runner::ExecutionContext.new.conversation_public_id, "and outside a task there is none"
  end

  def test_every_claim_carries_its_workspace_even_for_an_unfollowed_nested_child
    nested = row("t1", conversation: "grandchild", workspace: "ws-original").with(parent_public_id: "child")
    lane = Lane.new(rows: [nested, row("t2", workspace: "ws-second")])
    seen = {}
    subject = runner(lane, toolset do |_args, ctx|
      seen[ctx.task_key] = [ctx.workspace_public_id, ctx.conversation_public_id, ctx.scope]
      Rho::Runner::Result.ok("seen")
    end)
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1")
    subject.nudged(agent_loop_public_id: "loop-1", task_key: "t2")

    assert_equal ["ws-original", "grandchild", nil], seen.fetch("t1")
    assert_equal ["ws-second", nil, nil], seen.fetch("t2")
    assert_nil Rho::Runner::ExecutionContext.new.workspace_public_id
  end

  # THE PLACEMENT IS RESOLVED ON THE WORKER: inside the pool block, before the `tool_call` chain, the run asks
  # the toolsets for the row's placement and sets the context's env and
  # record ONCE — so a hook reads the conversation's root off the context,
  # the handler runs the placement's tool instance, and a resolver's read
  # (a member-plane GET on the host) never runs on the reactor. A row whose
  # binding names a root this host does not have lands on zero; a name the
  # registry no longer holds is still answered `failed`.
  def test_a_claim_resolves_its_placement_on_the_worker_and_the_context_carries_it
    Dir.mktmpdir("rho-runner-place") do |dir|
      tmp = File.realpath(dir)
      zero_root = File.join(tmp, "zero")
      bound_root = File.join(tmp, "bound")
      FileUtils.mkdir_p([zero_root, bound_root])
      zero = Rho::Runner::ToolEnv.new(root: zero_root, artifacts_dir: File.join(tmp, "work", "artifacts", "z"))
      registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
      seen = {}
      threads = {}
      hooks = Rho::Runner::Extensions::Hooks::Host.new([
        Rho::Runner::Extensions::Hooks::Registration.new(event: :tool_call, extension: "t", handler: lambda { |_name, arguments, _tool|
          context = Rho::Runner::ExecutionContext.current
          seen[context.task_key] = [context.tool_env&.root, context.binding&.anchor]
          arguments
        }),
      ])
      bindings = { "conv-1" => Rho::Runner::Environment::Binding.new(root: bound_root, directories: [], anchor: "conv-1"),
                   "conv-2" => Rho::Runner::Environment::Binding.new(root: File.join(tmp, "gone"), directories: [], anchor: "conv-2") }
      toolsets = Rho::Runner::Toolsets.new(registry: registry, zero: zero, work_dir: File.join(tmp, "work"),
        resolver: ->(conversation, _parent) { threads[conversation] = Thread.current; bindings[conversation] })
      lane = Lane.new(rows: [
        row("t1", tool: "ls", input: {}, conversation: "conv-1"),
        row("t2", tool: "ls", input: {}, conversation: "conv-2"),
        row("t3", tool: "ls", input: {}),
        row("t4", tool: "vanished", input: {}, conversation: "conv-1"),
      ].map { |task| task.with(agent_loop_public_id: "loop-#{task.task_key}") })
      pool = Rho::Runner::Pool.new(worker_threads: 2)
      subject = Rho::Runner.new(executor: lane, toolsets: toolsets, log: Silent.new, pool: pool,
        sleeper: ->(_) { nil }, hooks: hooks)
      %w[t1 t2 t3 t4].each { |key| subject.nudged(agent_loop_public_id: "loop-#{key}", task_key: key) }
      subject.stop

      assert_equal [bound_root, "conv-1"], seen.fetch("t1"), "the bound root's env and record on the context"
      assert_equal [zero_root, nil], seen.fetch("t2"), "a root absent on this host: zero, no record"
      assert_equal [zero_root, nil], seen.fetch("t3"), "a standalone row: zero"
      refute_same Thread.current, threads.fetch("conv-1"), "the resolver ran on a worker, never the reactor"
      by_key = lane.commits.to_h { |fields| [fields.fetch(:claim_token), fields] }
      assert_equal "completed", by_key.fetch("tok-t1").fetch(:outcome)
      assert_equal "failed", by_key.fetch("tok-t4").fetch(:outcome)
      assert_includes by_key.fetch("tok-t4").fetch(:content), "no longer serves \"vanished\""
      assert_equal registry.names.sort, subject.snapshot.tools.sort
    ensure
      pool&.stop
    end
  end
end
