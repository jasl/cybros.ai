require "test_helper"
require "support/live_journey"
require "json"
require "securerandom"
require "time"

# TWO LOOPS, ONE BROWSER, TWO TABS — the case the per-loop session exists
# for. Two `rho do`s on one daemon each drive the browser at the same
# time. Before this they took turns on one tab, and the second's
# navigation invalidated the first's refs; now each loop has its own
# page in one shared Chromium, and neither is ever told its tab was reset.
#
# THE PROOF IS IN FOUR PLACES, and the first is the one a shared tab
# cannot fake. Each loop TYPES its own value into the form and reads it
# back: on one shared tab the second loop's typing replaces the first's,
# so at least one loop reads back the other's value; on two tabs each
# reads its own. On disk: both wrote what they read. In the daemon's own
# log: no tab was dropped and no driver was stopped while they ran. In
# the process table: exactly one Chromium existed while both ran. And in
# the kernel's trace: the two loops' browser activity OVERLAPPED in time
# — asserted, not assumed, because the daemon once dispatched nudged
# tool calls one at a time on a single fiber and the overlap this change
# exists for happened only by luck.
#
# Paid, local, opt-in: E2E_LIVE=1, plus a Node Playwright driver.
class LiveTwoLoopsBrowserTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  DRIVER = ENV.fetch("RHO_BROWSER_PLAYWRIGHT_CLI", "npx -y playwright-core@1.62.1").freeze

  include E2E::LiveJourney

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-two-loops-e2e",
      daemon_env: { "RHO_BROWSER_PLAYWRIGHT_CLI" => DRIVER })
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.browser" => { "enabled" => true } })), perm: 0o600)
  end

  def teardown = finish_live_journey!

  def test_two_loops_drive_the_browser_at_once_on_their_own_tabs
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    url = "#{@base_url}/session/new"
    # ABSOLUTE PATHS, because the two loops share one runner root and
    # must not overwrite each other's proof.
    outputs = %w[a b].to_h { |tag| [tag, File.join(project, "page-#{tag}.json")] }
    marks = { "a" => "alpha-#{SecureRandom.hex(3)}@tabs.test", "b" => "beta-#{SecureRandom.hex(3)}@tabs.test" }
    task = lambda do |tag|
      <<~TEXT.strip
        Open #{url} in the browser. Type exactly #{marks[tag]} into the Email
        field (do not submit). Then read back the Email field's current value
        with browser_evaluate. Then write a file at exactly this absolute
        path: #{outputs[tag]} — a JSON object with three keys: "title" (the
        page's exact <title> text), "fields" (the visible labels of every
        text or password input, in order), and "email" (the value you read
        back). Nothing else. Reply DONE.
      TEXT
    end

    # BOTH STARTED BEFORE EITHER FINISHES. `rho do` returns as soon as the
    # loop is started, so the second is on the wire while the first's
    # rounds are still running.
    ids = %w[a b].map do |tag|
      output, status = @daemon.cli("do", task.call(tag), "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do (#{tag}) failed:\n#{output}"
      output[/^run:\s+(\S+)/, 1].tap { |id| refute_nil id, "no loop id (#{tag}):\n#{output}" }
    end

    chromiums = watch_chromium_count_while do
      @completed = ids.map { |id| await_loop_completion(id) }
    end
    @completed.zip(%w[a b]).each { |row, tag| report(row, tag) }

    @completed.each_with_index do |row, i|
      assert_equal "completed", row.fetch("status"), "loop #{ids[i]} did not finish: #{summarize(row)}"
      browser_calls = row.fetch("tasks").select do |t|
        t.fetch("kind") == "tool_task" && t.fetch("tool_name").start_with?("browser_") &&
          t.fetch("status") == "completed" && t.dig("result", "is_error") != true
      end
      refute_empty browser_calls, "loop #{ids[i]} never used the browser successfully"
    end

    # ON DISK, both — and each read back ITS OWN value, which one shared
    # tab cannot give both of them.
    outputs.each do |tag, path|
      assert_path_exists path
      document = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      assert_equal expected_title, document.fetch("title")
      labels = Array(document.fetch("fields")).map { |l| l.to_s.strip.downcase }
      assert_includes labels, "email"
      assert_includes labels, "password"
      assert_equal marks[tag], document.fetch("email").to_s.strip,
        "loop #{tag} read back a value it did not type — the tabs were shared"
    end

    # IN THE DAEMON'S LOG: nothing was dropped, nothing restarted, while
    # two loops shared the browser. The shutdown stop, logged as
    # `reason=closed`, is the one stop that belongs.
    log = File.read(File.join(@home, "log", "rho.log"), encoding: Encoding::UTF_8).scrub
    refute_match(/event=browser_tab_dropped/, log, "a tab was dropped while two loops ran")
    refute_match(/event=browser_driver_stopped reason=(?!closed\b)/, log,
      "the driver was restarted while two loops ran")

    # IN THE PROCESS TABLE: one Chromium, not two.
    assert_operator chromiums.max, :>=, 1, "no Chromium was ever seen running"
    assert_equal 1, chromiums.max, "the two loops did not share one browser: saw #{chromiums.max}"

    # IN TIME: the two loops' browser work overlapped.
    windows = @completed.map { |row| browser_window(row) }
    a, b = windows
    assert a && b, "a loop has no browser calls with timestamps"
    assert a.first < b.last && b.first < a.last,
      "the loops' browser activity did not overlap: #{a.inspect} vs #{b.inspect}"
  end

  private

    # Samples how many Playwright-launched browser MAIN processes THIS
    # DAEMON has while the block runs: an argv under Playwright's browser
    # cache, carrying the user-data-dir, NOT a helper (`--type=`) — and a
    # descendant of the daemon. Explicit about the helper exclusion,
    # because a channel or headless-mode change would otherwise count
    # renderers and GPU helpers as browsers; explicit about the ancestry,
    # because the machine is shared — another Playwright run on it (a
    # second session's own test suite, say) launches browsers of exactly
    # this argv shape, and a count that could not tell them from ours
    # once read 3 for a daemon that had opened one.
    def watch_chromium_count_while
      samples = []
      stop = false
      sampler = Thread.new do
        until stop
          samples << daemon_chromium_mains.size
          sleep 0.5
        end
      end
      yield
      stop = true
      sampler.join(2)
      samples
    end

    def daemon_chromium_mains
      rows = `ps -eo pid=,ppid=,args=`.lines.map do |line|
        pid, ppid, args = line.strip.split(/\s+/, 3)
        [pid.to_i, ppid.to_i, args.to_s]
      end
      parents = rows.to_h { |pid, ppid, _| [pid, ppid] }
      rows.select do |pid, _, args|
        args.include?("ms-playwright/") && args.include?("--user-data-dir") && !args.include?("--type=") &&
          descends_from?(pid, @daemon.pid, parents)
      end
    end

    # Up the ppid chain from `pid` towards init: a Chromium is the daemon's
    # if the daemon is above it — behind the Node driver and the shell
    # `npx` runs it through. A detached launch changes the browser's
    # session, not its parent, so the chain holds while the driver lives.
    def descends_from?(pid, ancestor, parents)
      steps = 0
      while pid && pid > 1 && steps < 32
        return true if pid == ancestor

        pid = parents[pid]
        steps += 1
      end
      false
    end

    # [earliest start, latest finish] of a loop's browser tool tasks, from
    # the kernel's own timestamps.
    def browser_window(row)
      stamps = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" && t.fetch("tool_name").start_with?("browser_") }
        .filter_map { |t| [t["started_at"], t["completed_at"]] if t["started_at"] && t["completed_at"] }
      return nil if stamps.empty?

      [stamps.map { |s, _| Time.iso8601(s) }.min, stamps.map { |_, c| Time.iso8601(c) }.max]
    end

    def expected_title
      uri = URI.join(@base_url, "/session/new")
      html = Net::HTTP.start(uri.hostname, uri.port) { |http| http.get(uri.path).body }
      raw = html.dup.force_encoding(Encoding::UTF_8)[%r{<title>(.*?)</title>}m, 1]
      refute_nil raw
      raw.strip.gsub(/&(?:#x([0-9a-f]+)|#(\d+)|(amp|lt|gt|quot));/i) do
        if Regexp.last_match(1) then Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8)
        elsif Regexp.last_match(2) then Regexp.last_match(2).to_i.chr(Encoding::UTF_8)
        else { "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"' }.fetch(Regexp.last_match(0))
        end
      end
    end

    def report(row, tag)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live two loops (#{tag}) --------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "--------------------------------------------------------------"
    end
end
