require "test_helper"
require "support/gallery/shapes"
require "support/live_journey"
require "support/task_bench"

# THE CROSS-TURN HALF OF THE TOOLS' BENCH, driven through `exe/rho`. `mail`: turn 1 is told to start
# a slow suite as a background task and answer meanwhile; the reply goes final with the branch still
# running (`rho watch` says `background:`), the kernel mails the `<task_result>` through the input
# door as a queued `direct_reply` that WAKES the kernel's own turn (awaited and asserted on: the
# person's turn 2 is submitted only once it ended, or a steer would land inside it), and turn 2 —
# one line from the person — must name the failing test FROM THE MAIL and never re-run the suite.
# `fan`: the blocking fan of five — one `task` per file in one message, the merge names all five, no
# second task for a delegated file, no graph verb inside a branch.
#
# What the KERNEL owes is asserted: once the model started a background
# task that outlived the reply, its answer must arrive as mail. What the
# MODEL did is measured and written to the readout, one row per run
# (each objective >= 2 of 3 runs on each weak model is the bar).
#
# E2E_LIVE=1 E2E_DEADLINE_SECONDS=5400 E2E_TEARDOWN_DEADLINE_SECONDS=600 rake live_task_mail
# E2E_TASK_MODELS=deepseek/deepseek-flash E2E_TASK_RUNS=1 E2E_TASK_LIVE_OBJECTIVES=mail …
# E2E_LIVE_ADAPTATIONS=claude # THE SWEEP'S ONE PAID exe/rho LANE UNDER A PACK ROW (capabilities #
# II 3.6): the world's rho home boots under a LOCAL row `sweep` # (`tool_style: [claude]` — the
# preset words, `+`-joined), so a live # model's reach for `Agent` through `rho do` is observed; the
# readout # keys the rows by `adaptations` beside the baseline's
#
# Paid, local, opt-in.
class LiveTaskMailTest < Minitest::Test
  # A bare `rake live_task_mail` runs the two-model matrix; the sweep's
  # E2E_LIVE_MODEL narrows it to one paid matrix per model (Gate 3 F6), and
  # the readout merges rather than overwrites.
  MODELS = ENV.fetch("E2E_TASK_MODELS") {
    ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_models.join(",") }
  }.split(",").freeze
  RUNS = Integer(ENV.fetch("E2E_TASK_RUNS", "3"))
  OBJECTIVES = ENV.fetch("E2E_TASK_LIVE_OBJECTIVES", "mail,fan").split(",").freeze
  # The style row the sweep boots under, checked against the pack's tables
  # BEFORE a world is paid for; nil is the daemon's default (`auto`).
  ADAPTATIONS = ENV["E2E_LIVE_ADAPTATIONS"].to_s.strip.then { |word| word.empty? ? nil : word }.freeze
  ADAPTATION_WORDS = (ADAPTATIONS && E2E::AdaptationRows.words(ADAPTATIONS)).freeze
  SWEEP_ROW = "sweep".freeze
  FILES = %w[a b c d e].freeze
  FAILING_TEST = "test_subtracts".freeze
  SUITE = "ruby test/all.rb".freeze

  MAIL_TURN_1 = "Start the test suite `#{SUITE}` as a background task now — it is slow and I do not want you " \
                "to wait for it. While it runs, count the files in lib/ and reply with just that number. " \
                "Do not wait for the suite before you reply.".freeze
  MAIL_TURN_2 = "Which test failed? Answer with the failing test's method name only.".freeze
  FAN_TURN = "Review each of #{FILES.map { |f| "lib/#{f}.rb" }.join(", ")}: in every file one method is defined " \
             "but never called anywhere in lib/. Give one review per file to a separate agent, all at once, " \
             "then merge the five answers into one list, one line per file: `lib/<file>.rb — <method>`.".freeze

  include E2E::LiveJourney

  @runs = []
  class << self
    attr_reader :runs
  end

  def teardown = finish_live_journey!

  Minitest.after_run do
    next if runs.empty?

    E2E::TaskBench::Report.write_live(runs)
    puts "\nreadout: #{E2E::TaskBench::Report.bench_dir}"
  end

  MODELS.each do |model|
    OBJECTIVES.each do |objective|
      (1..RUNS).each do |run|
        define_method(:"test_#{objective}_#{run}_on_#{model.tr("/.-", "___")}") do
          start_live_journey!(model, home_prefix: "rho-live-task-#{objective}")
          write_sweep_row! if ADAPTATIONS
          connect_and_open_lane!
          record = send(:"run_#{objective}", model)
          self.class.runs << record.merge("objective" => objective, "model" => model, "run" => run)
            .merge(ADAPTATIONS ? { "adaptations" => "#{SWEEP_ROW}:#{ADAPTATIONS}" } : {})
          puts "\n--- live task #{objective} ##{run} on #{model}: #{record["pass"] ? "PASS" : "FAIL"} #{record.to_json}"
        end
      end
    end
  end

  private

    # The local row `sweep` contains only the named preset words under the home's
    # `adaptations/`, selected by `settings.json`; the daemon's declaration
    # is then that row's set (`Agent` in place of `task` under `claude`). Over the dev set: a
    # written file is the lane's own word.
    def write_sweep_row!
      write_daemon_home!(settings: E2E::RhoDaemon::DEV_SETTINGS.merge("adaptations" => SWEEP_ROW),
        local_rows: { SWEEP_ROW => YAML.dump(E2E::AdaptationRows.word_row(SWEEP_ROW, ADAPTATION_WORDS)) })
    end

    # TURN 1 → the reply is final while the suite runs → the mail wakes the
    # KERNEL'S turn, which ends → TURN 2, the person's. What the kernel owes
    # is asserted (the mail, and the turn it wakes); what the model did with
    # the receipt in its woken turn and in turn 2 is measured.
    def run_mail(model)
      project = mail_project!
      conversation, _turn, loop_one = open_turn(MAIL_TURN_1, model, project)
      watched, status = rho_watch(loop_one, "--timeout", "600")
      assert_predicate status, :success?, watched
      assert_match(/^status:\s+completed$/, watched, watched)
      background = watched.match?(/^background: /)
      row = await_loop_completion(loop_one)
      started = row.fetch("tasks").any? { |task| task["tool_name"] == "delegate_task" }
      # What turn 1 reached for, so a `task_started=false` row says what
      # the model called instead (the neutral wording is the measurement).
      turn_1_called = row.fetch("tasks").filter_map { |task| task["tool_name"] }.tally

      mailed = nil
      woken = nil
      if background
        mailed = await_mail(conversation)
        refute_nil mailed, "the kernel owes the mail once a background task outlived the reply"
        assert_equal %w[direct_reply queue], mailed.fetch("payload").values_at("kind", "delivery_mode"),
          "the receipt is a queued reply, never a steer: #{mailed.inspect}"
        await_loop_completion(loop_one)
        woken = await_next_turn(conversation, after: [loop_one])
        await_loop_completion(woken)
      end

      said, status = @daemon.cli("say", conversation, MAIL_TURN_2)
      assert_predicate status, :success?, said
      loop_two = await_next_turn(conversation, after: [loop_one, woken].compact)
      done = await_loop_completion(loop_two)
      reply, = @daemon.cli("result", loop_two)
      reran = done.fetch("tasks").select { |task| task["kind"] == "tool_task" }.any? { |task| reruns_suite?(loop_two, task) }
      named = reply.to_s.include?(FAILING_TEST)
      in_mail = mail_before_turn?(conversation, done)
      { "pass" => started && background && !mailed.nil? && in_mail && named && !reran,
        "task_started" => started, "turn_1_called" => turn_1_called,
        "reply_final_with_background" => background, "mailed" => !mailed.nil?,
        "receipt_woke_a_turn" => !woken.nil?,
        "mail_in_turn_2_history" => in_mail, "named_the_failing_test" => named, "reran_the_suite" => reran,
        "reply" => reply.to_s.strip[0, 200] }
    end

    def run_fan(model)
      project = fan_project!
      _conversation, _turn, loop_id = open_turn(FAN_TURN, model, project)
      done = await_loop_completion(loop_id)
      tasks = done.fetch("tasks")
      calls = tasks.select { |task| task["tool_name"] == "delegate_task" }
      # THE FIRST MESSAGE IS r1's CALLS, read by `after`: the kernel keys a round's calls with its
      # continuation's number (r1 makes `r2t0`…), so no key shape names them.
      first_round = calls.select { |task| Array(task["after"]).include?("r1") }
      prompts = calls.map { |task| task_input(loop_id, task["key"]).fetch("prompt", "").to_s }
      per_file = FILES.to_h { |f| [f, prompts.count { |prompt| prompt.include?("#{f}.rb") }] }
      reply, = @daemon.cli("result", loop_id)
      names_all = FILES.all? { |f| reply.to_s.include?("#{f}.rb") }
      no_second = per_file.values.all? { |n| n <= 1 }
      # THE MAINLINE IS THE KERNEL'S MARK (the graph route's `mainline` on every round): a graph verb a
      # round marked the mainline's made is the mainline's; any other — a branch's root, a delegate's own
      # round, keyed `rN` on the same counter — is inside a branch. A fan the model placed on a LATER
      # mainline round is "looked first, then fanned", counted on its own.
      mainline = E2E::Gallery.mainline_keys(agent_api("#{loop_path(loop_id)}/graph"))
      graph_verbs = tasks.select { |task| task["tool_name"] == "delegate_task" }
      mainline_made = graph_verbs.select { |task| Array(task["after"]).intersect?(mainline) }
      in_branches = (graph_verbs - mainline_made).size
      later = (mainline_made - first_round).size
      { "pass" => first_round.length >= 5 && names_all && no_second && in_branches.zero? && done["status"] == "completed",
        "status" => done["status"], "task_calls_in_first_message" => first_round.length,
        "task_calls_in_a_later_round" => later,
        "merge_names_all_five" => names_all, "no_second_task_per_file" => no_second,
        "graph_verbs_inside_branches" => in_branches, "per_file" => per_file, "reply" => reply.to_s.strip[0, 300] }
    end

    # THE MAIL IS IN TURN 2's HISTORY when the receipt's OWN turn — the kernel-stamped
    # `direct_reply` with origin `task_result` the drain woke (the receipt queues, drains first and
    # opens a loop-backed turn whose trailing user text is the envelope) — sits on the timeline
    # BEFORE turn 2. Read off the timeline: a real model does not echo its input, so its reply can
    # never testify to what it was shown. What turn 2 renders of it is the woken turn's SEED — the
    # envelope itself, in the user role — then the woken turn's answer, so `named` measures the
    # model reading the receipt FROM turn 2's history, no longer through the woken turn's
    # paraphrase.
    def mail_before_turn?(conversation, loop_row)
      turns = timeline(conversation)
      position = turns.find { |turn| turn["public_id"] == loop_row.dig("turn", "public_id") }&.fetch("position")
      return false if position.nil?

      turns.any? { |turn| turn["origin"] == "task_result" && turn["kind"] == "direct_reply" && turn["position"] < position }
    end

    def timeline(conversation)
      turns = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/turns" \
          "?limit=100#{after ? "&after_position=#{after}" : ""}")
        rows = Array(page["turns"])
        turns.concat(rows)
        after = page.dig("pagination", "after_position")
        break if rows.empty? || after.nil?
      end
      turns
    end

    def reruns_suite?(loop_id, task)
      return false unless task["tool_name"] == "bash"

      command = task_input(loop_id, task["key"]).fetch("command", "").to_s
      command.include?("all.rb") || command.include?("calc_test") || command.include?("_test.rb")
    end

    # A tiny suite that FAILS one named test and takes long enough that a
    # reply written meanwhile goes final before it (the mock journey's
    # `sleep 20` for the same reason).
    def mail_project!
      project = File.join(@home, "project")
      FileUtils.mkdir_p(File.join(project, "lib"))
      FileUtils.mkdir_p(File.join(project, "test"))
      %w[calc greet shout].each do |name|
        File.write(File.join(project, "lib", "#{name}.rb"), "module #{name.capitalize}\n  def self.call(x) = x\nend\n")
      end
      File.write(File.join(project, "lib", "calc.rb"), <<~RUBY)
        module Calc
          def self.add(a, b) = a + b
          def self.sub(a, b) = a + b
        end
      RUBY
      File.write(File.join(project, "test", "calc_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/calc"

        class CalcTest < Minitest::Test
          def test_adds = assert_equal(3, Calc.add(1, 2))
          def #{FAILING_TEST} = assert_equal(1, Calc.sub(3, 2))
        end
      RUBY
      File.write(File.join(project, "test", "all.rb"), <<~RUBY)
        sleep 45 # the suite is slow on purpose: the reply must go final before it
        Dir[File.join(__dir__, "*_test.rb")].each { |file| require file }
      RUBY
      @daemon.control(:post, "/environment", body: { root: project })
      project
    end

    # Exactly ONE uncalled method per file, as the prompt asserts: `call`
    # is called from `lib/run.rb`, so `orphan_<f>` is the only answer and a
    # model reading the fixture literally has nothing to keep verifying.
    def fan_project!
      project = File.join(@home, "project")
      FileUtils.mkdir_p(File.join(project, "lib"))
      FILES.each do |f|
        File.write(File.join(project, "lib", "#{f}.rb"), <<~RUBY)
          module #{f.upcase}
            def self.used_#{f}(x) = x * 2
            def self.orphan_#{f}(x) = x * 3
            def self.call(x) = used_#{f}(x)
          end
        RUBY
      end
      File.write(File.join(project, "lib", "run.rb"), <<~RUBY)
        #{FILES.map { |f| "require_relative \"#{f}\"" }.join("\n")}

        #{FILES.map { |f| "#{f.upcase}.call(1)" }.join("\n")}
      RUBY
      @daemon.control(:post, "/environment", body: { root: project })
      project
    end

    def open_turn(prompt, model, project)
      output, status = @daemon.cli("do", prompt, "--model", model, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def await_mail(conversation, deadline: 300)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation).find { |item| item["type"] == "input_accepted" && item.dig("payload", "origin") == "task_result" }
        return found if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    # The first turn the feed opened on a loop other than `after` (an
    # Array: turn 1's, and the receipt's woken one once it is known).
    def await_next_turn(conversation, after:, deadline: LOOP_DEADLINE_SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "run_public_id") &&
            item.dig("payload", "turn_kind") != "compaction_summary" &&
            !after.include?(item.dig("payload", "run_public_id"))
        end
        return found.dig("payload", "run_public_id") if found
        raise "the next turn never started" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def loop_path(loop_id) = "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}"

    def task_output(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").dig("task", "output").to_s

    def task_input(loop_id, key) = Hash(agent_api("#{loop_path(loop_id)}/tasks/#{key}").dig("task", "tool_input"))
end
