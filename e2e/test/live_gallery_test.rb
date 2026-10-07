require "test_helper"
require "support/live_journey"
require "support/gallery/shapes"
require "support/evals/report_line"
require "json"

# THE LOOP-SHAPE GALLERY: nine tasks of deliberately different shape on a real model, each loop's
# picture exported and asserted against the shape it was built to produce. The picture is evidence,
# not decoration — `E2E::Gallery`'s predicates read the graph route's nodes and edges beside the
# loop row's tasks and the feed's items, and name kinds, edges and error keys only; what a model may
# vary (round counts, fan widths, which round asks) is printed, never asserted.
#
# WHAT AN ARTIFACT HOLDS. Under e2e/artifacts/gallery/ (git-ignored, the
# bench's shape): `<shape>.<model>.md` — the expected-shape sentence, the
# verdict, and the mermaid the route drew, fenced; `<shape>.<model>.json`
# — the route's graph, the loop row's tasks joined with each tool call's
# `tool_input`, the feed's `context_compacted`/`attention_required`/
# `input_accepted`/`turn_status` items, and the verdict. The
# detached_receipt shape exports BOTH loops (`.1.json`, `.2.json`).
#
# TWO DAEMONS, NOT NINE. A daemon per shape would spend a device grant
# and a ceremony per shape, so one method runs every kernel-mode shape in
# one daemon, each in its own project dir under the same home, and one
# method runs the delegate compaction shape in a home whose settings.json
# names `compaction: delegate` before the daemon starts (as
# live_long_session does). A shape's failure — a red predicate, a raised
# driver, a deadline — is CAUGHT per shape and recorded as a red row with
# its picture; the method asserts at the end that no row is red, so one
# red shape never hides the others' pictures.
#
# THE MANUAL DOOR. Prune cannot be switched off (the policy's modes are kernel|delegate|off) and
# answers every byte wall on a read-heavy loop, so a kernel or delegate SUMMARY on a real model is
# forced through `POST …/tasks/{key}/compact` on a round that is queued while its predecessor's
# `sleep 20` runs — the member plane, as live_repair authors the halting loop rho cannot; `rho
# compact ID TASK_KEY` — the Ops extension's verb — is the CLI's door to the same route, and the
# gallery drives the route directly to keep the shape's timing. This is the first observation of
# rho's summarizer prompt, and of a kernel summary at all, on a real model; the two compaction
# shapes write `k1`'s summary beside the picture (`<shape>.<model>.summary.md`) so its pointer lines
# can be read off the artifact.
#
# `rho graph ID` is run once per shape and must print the route's mermaid
# byte for byte. E2E_GALLERY_ONLY=linear,until_gate filters the shapes.
#
# Paid, local, opt-in: E2E_LIVE=1, on E2E_LIVE_MODEL. Budget: nine loops
# of a few rounds each, ≈ 30–40 min per model.
class LiveGalleryTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  ONLY = ENV.fetch("E2E_GALLERY_ONLY", "").split(",").map(&:strip).reject(&:empty?).map(&:to_sym).freeze
  ARTIFACTS = File.expand_path("../artifacts/gallery", __dir__)
  # THE ANSWER CANNOT BE GUESSED (live_human_in_the_loop's SECRET).
  SECRET = "marmalade".freeze
  SHAPE_DEADLINE_SECONDS = 600
  LONG_SHAPE_DEADLINES = { fan_join: 900, detached_receipt: 900 }.freeze
  EVENT_TYPES = %w[context_compacted attention_required input_accepted turn_status].freeze
  VERDICT_LINE = "%-24s %-40s %-5s %4ds  %s".freeze

  Run = Data.define(:loop, :conversation, :extra_loops)
  Picture = Data.define(:label, :loop, :status, :graph, :tasks, :events)
  Verdict = Data.define(:id, :ok, :reason, :seconds, :pictures)

  include E2E::LiveJourney

  def setup
    @shapes = shapes_for(name)
    skip "E2E_GALLERY_ONLY=#{ONLY.join(",")} names none of this method's shapes" if @shapes.empty?
    start_live_journey!(MODEL, home_prefix: "rho-live-gallery-e2e")
    return unless @shapes.all?(&:delegate?)

    # BEFORE THE DAEMON STARTS: the flag is read at boot, and the delegate needs a model for its
    # InferenceRequest — this lane's. Over the dev set: a written file is the lane's own word.
    File.write(File.join(@home, "settings.json"),
      JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.compaction" => { "configuration" => { "mode" => "delegate", "model" => MODEL } } })), perm: 0o600)
  end

  def teardown = finish_live_journey!

  def test_the_kernel_mode_shapes = run_gallery

  def test_the_delegate_compaction_shape = run_gallery

  private

    def shapes_for(method_name)
      rows = E2E::Gallery::SHAPES.select { |shape| shape.delegate? == method_name.include?("delegate") }
      ONLY.empty? ? rows : rows.select { |shape| ONLY.include?(shape.id) }
    end

    def run_gallery
      connect_and_open_lane!
      verdicts = @shapes.map do |shape|
        verdict = run_shape(shape)
        write_artifacts(shape, verdict)
        puts format(VERDICT_LINE, shape.id, MODEL, verdict.ok ? "pass" : "FAIL", verdict.seconds, verdict.reason.to_s)
        report_line(shape, verdict)
        verdict
      end
      puts "\n#{verdicts.size} shapes, #{verdicts.count { |v| !v.ok }} red; artifacts under #{ARTIFACTS}"
      reds = verdicts.reject(&:ok)
      assert_empty reds.map(&:id), "red shapes:\n\n#{reds.map { |v| red_message(v) }.join("\n\n")}"
    end

    # ONE SHAPE: its own project dir, its driver, the picture read off the
    # member plane and printed through the binary, the predicate. Anything
    # that fails is this shape's red row; the picture, if any was read, rides with it.
    def run_shape(shape)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      run = nil
      pictures = []
      puts "\n--- gallery: #{shape.id} on #{MODEL} --------------------------"
      project = project_for(shape)
      run = send(:"drive_#{shape.driver}", shape, project)
      pictures = pictures_of(run)
      assert_the_binary_prints_the_route_picture!(run.loop, pictures.first.graph)
      report(shape, pictures.first)
      answer = shape.predicate.call(pictures.first.graph, pictures.first.tasks, pictures.first.events)
      Verdict.new(id: shape.id, ok: answer == true, reason: (answer == true ? nil : answer.to_s),
        seconds: elapsed(started), pictures: pictures)
    rescue StandardError, Minitest::Assertion => error
      pictures = salvage(run) if pictures.empty? && run
      Verdict.new(id: shape.id, ok: false, reason: "#{error.class}: #{error.message.lines.first.to_s.strip[0, 300]}",
        seconds: elapsed(started), pictures: pictures)
    ensure
      send(:"after_#{shape.driver}", run) if run && respond_to?(:"after_#{shape.driver}", true)
    end

    def project_for(shape)
      project = File.join(@home, "shapes", shape.id.to_s)
      FileUtils.mkdir_p(project)
      shape.files.each do |path, contents|
        full = File.join(project, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      @daemon.control(:post, "/environment", body: { root: project })
      project
    end

    def deadline_for(shape) = LONG_SHAPE_DEADLINES.fetch(shape.id, SHAPE_DEADLINE_SECONDS)

    def elapsed(started) = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round

    # ── the drivers: each opens the loop THROUGH THE BINARY and scripts the
    # one human step its shape needs, then answers the loop(s) to picture ──

    def drive_plain(shape, project)
      conversation, loop_id = open_turn(shape.task, project)
      await_loop_completion(loop_id, deadline: deadline_for(shape))
      # A background branch can outlive the model's final reply; read the
      # picture once every task has settled.
      await_tasks_settled(loop_id, deadline: deadline_for(shape))
      Run.new(loop: loop_id, conversation: conversation, extra_loops: [])
    end

    def drive_answer_ask(shape, project)
      conversation, loop_id = open_turn(shape.task, project)
      asking = await_attention(loop_id, deadline: 300)
      key = Array(asking.dig("attention", "blocked_task_keys")).first
      refute_nil key, "the ask named no task to answer: #{asking.inspect}"
      puts "asked:   #{key} #{task_detail(loop_id, key)["prompt"].inspect}"
      answered, status = @daemon.cli("answer", loop_id, key, SECRET)
      assert_predicate status, :success?, "rho answer failed:\n#{answered}"
      await_loop_completion(loop_id, deadline: deadline_for(shape))
      Run.new(loop: loop_id, conversation: conversation, extra_loops: [])
    end

    # live_repair's shape, verbatim: the halt is authored over the member
    # plane, the person abandons one gate and retries the other.
    def drive_halting_loop(shape, _project)
      loop_id, tokens = author_halting_loop!
      await_halt(loop_id, deadline: deadline_for(shape))
      abandoned, status = @daemon.cli("abandon", loop_id, "gate-1")
      assert_predicate status, :success?, abandoned
      retried, status = @daemon.cli("retry", loop_id)
      assert_predicate status, :success?, "one candidate left, so no key was needed:\n#{retried}"
      answered, status = @daemon.cli("answer", loop_id, "gate-2", "go ahead", "--token", tokens.fetch("gate-2"))
      assert_predicate status, :success?, answered
      await_loop_completion(loop_id, deadline: deadline_for(shape))
      Run.new(loop: loop_id, conversation: nil, extra_loops: [])
    end

    def drive_compact_queued_round(shape, project)
      conversation, loop_id = open_turn(shape.task, project)
      compact_a_queued_round!(loop_id, deadline: deadline_for(shape))
      await_loop_completion(loop_id, deadline: deadline_for(shape))
      Run.new(loop: loop_id, conversation: conversation, extra_loops: [])
    end

    def drive_until(shape, project)
      output, status = @daemon.cli("do", shape.task, "--model", MODEL, "--dir", project,
        "--until", "sh check.sh", "--attempts", "3")
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      assert_match(/^until:\s+sh check\.sh \(3 checks, in #{Regexp.escape(project)}\)/, output, output)
      conversation, loop_id = ids_of(output)
      await_loop_completion(loop_id, deadline: deadline_for(shape))
      Run.new(loop: loop_id, conversation: conversation, extra_loops: [])
    end

    # live_task_mail's `mail`: the reply goes final with the suite still
    # running, the kernel mails the receipt, the mail wakes a second loop.
    # No `rho say`: the shape IS the two loops.
    def drive_say_second_turn(shape, project)
      conversation, loop_one = open_turn(shape.task, project)
      watched, status = rho_watch(loop_one, "--timeout", "600")
      assert_predicate status, :success?, watched
      row = await_loop_completion(loop_one, deadline: deadline_for(shape))
      puts "watch:   background line #{watched.match?(/^background: /) ? "present" : "ABSENT"}"
      # No `task` call: the predicate's first line is the finding, and it
      # must carry the picture of what the model called instead — so the
      # run is answered now, with no mail to wait 300 s for.
      unless row.fetch("tasks").any? { |task| task["tool_name"] == "delegate_task" }
        puts "no task: #{summarize(row)}"
        return Run.new(loop: loop_one, conversation: conversation, extra_loops: [])
      end
      mailed = await_mail(conversation, deadline: 300)
      refute_nil mailed, "the kernel owes the mail once a background task outlived the reply"
      await_loop_completion(loop_one, deadline: deadline_for(shape))
      woken = await_next_turn(conversation, after: [loop_one], deadline: 300)
      await_loop_completion(woken, deadline: deadline_for(shape))
      Run.new(loop: loop_one, conversation: conversation, extra_loops: [woken])
    end

    # The brake parks the loop `needs_attention`, which is terminal for a
    # watcher; the picture is read held, then `after_brake` stops it.
    def drive_brake(shape, project)
      conversation, loop_id = open_turn(shape.task, project)
      begin
        await_loop_completion(loop_id, deadline: deadline_for(shape))
      rescue StandardError
        # A model that varies its call never trips the brake and never
        # ends ("do not give up"): the deadline is the finding, and the
        # loop is stopped so the next shape starts clean.
        stop_conversation!(conversation)
        raise
      end
      Run.new(loop: loop_id, conversation: conversation, extra_loops: [])
    end

    def after_brake(run)
      stop_conversation!(run.conversation)
    end

    def stop_conversation!(conversation)
      stopped, status = @daemon.cli("stop", conversation)
      puts "stop:    #{stopped.lines.first.to_s.strip} (#{status.success? ? "ok" : "refused"})"
    end

    # ── the manual door ────────────────────────────────────────────────────

    # THE WINDOW IS A QUEUED ROUND: the continuation of a round whose tool
    # is still running. The task sleeps twice, so there are two; a round
    # with no history behind it is refused `nothing_to_compact` and the
    # next one is tried. Accepted once, or the loop settled first.
    def compact_a_queued_round!(loop_id, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      refused = {}
      loop do
        row = loop_row(loop_id)
        if settled?(row)
          raise "the loop settled (#{row["status"]}) before the door armed; refusals: #{refused.inspect}"
        end

        row.fetch("tasks").select { |t| queued_model_task?(t) && !refused.key?(t["key"]) }.each do |round|
          body, code = agent_api_post("#{loop_path(loop_id)}/tasks/#{round["key"]}/compact", {})
          if code == 202
            puts "door:    compacted #{round["key"]} → #{body["summary_task_key"]}"
            return body
          end
          refused[round["key"]] = body.dig("error", "code") || body.to_s[0, 120]
          puts "door:    #{round["key"]} refused #{code} #{refused[round["key"]]}"
        end
        raise "the door never armed within #{deadline} s; refusals: #{refused.inspect}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 1
      end
    end

    def queued_model_task?(task)
      task["kind"] == "model_task" && task["status"] == "waiting" && task["key"] != "r1"
    end

    def settled?(row)
      (CybrosAgent::Api::RUN_TERMINAL_STATUSES + ["needs_attention"]).include?(row.fetch("status"))
    end

    # ── the picture ────────────────────────────────────────────────────────

    def pictures_of(run)
      [picture("1", run.loop, run.conversation),
       *run.extra_loops.each_with_index.map { |loop_id, index| picture((index + 2).to_s, loop_id, run.conversation) }]
    end

    def salvage(run)
      pictures_of(run)
    rescue StandardError => error
      warn "no picture could be salvaged: #{error.class}: #{error.message}"
      []
    end

    # The route's JSON as served; the loop row's tasks with each tool
    # call's `tool_input` joined from the single-task read (the trace
    # omits the arguments); the feed's items of the four types.
    def picture(label, loop_id, conversation)
      graph = agent_api("#{loop_path(loop_id)}/graph")
      row = loop_row(loop_id)
      tasks = row.fetch("tasks").map do |task|
        next task unless task["kind"] == "tool_task"

        task.merge("tool_input" => task_detail(loop_id, task.fetch("key"))["tool_input"])
      end
      events = feed(conversation, loop_id).select { |item| EVENT_TYPES.include?(item["type"]) }
      Picture.new(label: label, loop: loop_id, status: row.fetch("status"), graph: graph, tasks: tasks, events: events)
    end

    # THE CLI'S PICTURE IS THE ROUTE'S, byte for byte (the workspace_dedication
    # pin, extended): what a person pastes into a renderer is what the
    # kernel drew.
    def assert_the_binary_prints_the_route_picture!(loop_id, graph)
      printed, status = @daemon.cli("graph", loop_id)
      assert_predicate status, :success?, "rho graph failed:\n#{printed}"
      assert_match(/\Aflowchart TD$/, printed, printed)
      assert_equal graph.fetch("mermaid"), printed.chomp, "rho graph prints the route's mermaid"
    end

    def write_artifacts(shape, verdict)
      FileUtils.mkdir_p(ARTIFACTS)
      stem = File.join(ARTIFACTS, "#{shape.id}.#{MODEL.tr("/", "_")}")
      verdict_line = verdict.ok ? "pass" : "FAIL: #{verdict.reason}"
      markdown = +"# #{shape.id} on #{MODEL}\n\n#{shape.expected}\n\nverdict: #{verdict_line}\n"
      markdown << "\n(no picture was read)\n" if verdict.pictures.empty?
      verdict.pictures.each do |picture|
        markdown << "\n## loop #{picture.label}: #{picture.loop} (#{picture.status})\n\n" \
                    "```mermaid\n#{picture.graph.fetch("mermaid")}\n```\n"
      end
      File.write("#{stem}.md", markdown)
      write_summary_artifact(shape, verdict, stem)
      verdict.pictures.each do |picture|
        suffix = verdict.pictures.one? ? "" : ".#{picture.label}"
        File.write("#{stem}#{suffix}.json", JSON.pretty_generate({
          "shape" => shape.id, "model" => MODEL, "expected" => shape.expected, "loop" => picture.loop,
          "status" => picture.status, "graph" => picture.graph, "tasks" => picture.tasks, "events" => picture.events,
          "verdict" => verdict_line,
        }))
      end
    end

    # THE SUMMARY BESIDE THE PICTURE: the two compaction shapes force `k1` through the manual door,
    # and its output body is the only place the kernel's pointer lines (`Tool <name> (<status>,
    # <outcome>)`) can be read on a real model once the world is torn down. A shape that never
    # reached `k1` writes nothing; a read that fails is written as its error, never raised — the
    # artifact is evidence, not a gate.
    def write_summary_artifact(shape, verdict, stem)
      return unless shape.driver == :compact_queued_round

      picture = verdict.pictures.find { |p| p.tasks.any? { |t| t["key"] == "k1" } }
      return if picture.nil?

      body = task_output(picture.loop, "k1")
      File.write("#{stem}.summary.md", "# #{shape.id} on #{MODEL}: k1's summary\n\n#{body}\n")
    rescue StandardError => error
      File.write("#{stem}.summary.md", "# #{shape.id} on #{MODEL}: k1's summary\n\n(not read: #{error.class}: #{error.message})\n")
    end

    def task_output(loop_id, key) = task_detail(loop_id, key)["output"].to_s

    def red_message(verdict)
      pictures = verdict.pictures.map { |picture| "loop #{picture.label} #{picture.loop}:\n#{picture.graph.fetch("mermaid")}" }
      "#{verdict.id}: #{verdict.reason}\n#{pictures.empty? ? "(no picture)" : pictures.join("\n")}"
    end

    # the one report line every paid lane prints (`LiveJourney#report_loop!`: the spend and the
    # sealed request's bytes through the evals reader), off the first picture (a shape with none
    # prints its dashes); the shape's other loops are its own and print no line of their own.
    def report_line(shape, verdict)
      picture = verdict.pictures.first
      row = picture && { "public_id" => picture.loop, "status" => picture.status, "tasks" => picture.tasks }
      report_loop!(row, task: shape.id.to_s, events: picture&.events, seconds: verdict.seconds,
        reached: picture && picture.tasks.any? { |t| t["kind"] == "tool_task" }, succeeded: verdict.ok)
      verdict.pictures.each { |other| @reported_loops << other.loop }
    end

    # What the model did, printed whatever the verdict.
    def report(shape, picture)
      tools = picture.tasks.select { |t| t["kind"] == "tool_task" }
      puts "run:    #{picture.loop} #{picture.status}"
      puts "rounds:  #{picture.tasks.count { |t| t["kind"] == "model_task" }}"
      puts "calls:   #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "events:  #{picture.events.map { |e| e["type"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")}"
      puts "expect:  #{shape.expected}"
    end

    # ── the member-plane and daemon reads every lane keeps a copy of ───────

    def open_turn(task, project)
      output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids_of(output)
    end

    def ids_of(output)
      ids = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed no conversation or loop id:\n#{output}"
      ids
    end

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}"

    def task_detail(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")

    # A loop backing a turn has no feed of its own — its items ride its
    # conversation's; a standalone loop (the authored halt) has its own.
    def feed(conversation, loop_id)
      base = conversation ? "/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" :
        "#{loop_path(loop_id)}/events"
      items = []
      after = nil
      loop do
        page = agent_api("#{base}?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    # The daemon's rows are keyed by the HOST and carry every loop that
    # backed it, so a loop id finds its row through `loops`, the way `rho watch` does.
    def followed(loop_id)
      @daemon.control(:get, "/followers").fetch("followers").find do |row|
        row.fetch("public_id") == loop_id || Array(row["run_public_ids"]).include?(loop_id)
      end
    end

    def await_attention(loop_id, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        row = followed(loop_id)
        return row if row && row["attention"]
        flunk "the loop finished without ever asking: #{row.fetch("status")}" if row && row["complete"]
        flunk "the model never asked: #{row.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 2
      end
    end

    def await_tasks_settled(loop_id, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        row = loop_row(loop_id)
        live = row.fetch("tasks").reject { |t| E2E::Gallery::TERMINAL_TASK_STATUSES.include?(t["status"]) }
        return row if live.empty? || row["status"] == "needs_attention"
        raise "tasks still live after #{deadline} s: #{live.map { |t| describe_task(t) }.join(" ")}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    def await_mail(conversation, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation, nil).find do |item|
          item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result"
        end
        return found if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    # The first turn the feed opened on a loop other than `after`.
    def await_next_turn(conversation, after:, deadline:)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation, nil).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "run_public_id") &&
            item.dig("payload", "turn_kind") != "compaction_summary" &&
            !after.include?(item.dig("payload", "run_public_id"))
        end
        return found.dig("payload", "run_public_id") if found
        raise "the receipt woke no turn" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    # live_repair's authored halt: two one-second asks with `halt` in one
    # fan, and a round placed after them. Answers the loop id and the
    # resolution tokens the receipt returned.
    def author_halting_loop!
      path = "/agent_api/v1/workspaces/#{workspace_public_id}/runs"
      gates = [1, 2].map do |n|
        { "ask" => { "key" => "gate-#{n}", "prompt" => "gate #{n}", "timeout_ms" => 1000, "on_failure" => "halt" } }
      end
      body, status = agent_api_post(path, { "run" => {
        "steps" => [
          { "parallel" => gates },
          { "model" => { "key" => "work", "prompt" => "Reply with exactly DONE.", "model" => { "model" => MODEL } } },
        ],
        "approval_mode" => "bypass",
      } })
      assert_equal 201, status, "authoring the halting loop: #{body}"
      loop_id = body.dig("run", "public_id")
      tokens = body.dig("receipt", "resolution_tokens") || {}
      assert_equal %w[gate-1 gate-2], tokens.keys.sort, "an authored await is minted a token"
      _, started = agent_api_post("#{path}/#{loop_id}/start", {})
      assert_equal 200, started, "starting the halting loop"
      @daemon.control(:post, "/followers/subscribe", body: { public_id: loop_id })
      [loop_id, tokens]
    end
end
