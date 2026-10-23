require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# A model's command parks on rho's inbox until the person approves it through the CLI.
# The other journeys prove installation-edit refusals before Runner execution and prefix/path
# grants across later calls. Each owns its daemon home and shares the steward browser session.
class ApprovalTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  COMMAND = "printf held > held.txt".freeze
  REASON = "use ls".freeze
  QUESTION = "which database?".freeze
  # Pin the explanation returned by rho's self-modification deny rule byte for byte.
  INCUBATION = "direct installation edits are disabled; use managed extensions or develop a separate rho successor".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-approval-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/approval-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture approval E2E capture: #{error.class}: #{error.message}"
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  # THE GRANT. The park on every surface a person reads — the trace, the
  # daemon's row, the log, the inbox, `rho status`, `rho watch`, `rho
  # task` — then `rho approve` releases the call to rho's runner, which
  # runs it; the fact reads `agent`, because rho's member bearer is the
  # Agent user's (the steward's own approve would read `human`).
  def test_a_command_under_ask_rests_for_the_person_on_rhos_inbox_and_rho_approve_releases_it
    project = connect!
    conversation, _turn, loop = open_turn(bash_prompt(COMMAND, "done"), project, "--approval", "ask")
    held = await_park(loop)
    key = held.fetch("key")

    # THE PARK: a real rest state of the tool row, addressed to rho's Agent,
    # announced on the loop while the turn stays `running`.
    row = loop_row(loop)
    assert_equal "running", row.fetch("status"), summarize(row)
    assert_equal({ "reason" => "approval_required", "blocked_task_keys" => [key] }, row.fetch("attention"))
    assert_equal "agent", held.dig("addressed_to", "role"), held.inspect
    followed = await_followed_attention(loop)
    assert_equal({ "reason" => "approval_required", "blocked_task_keys" => [key] }, followed.fetch("attention"),
      "the daemon's row names the held key")
    detail = task_detail(loop, key)
    assert_equal COMMAND, detail.dig("tool_input", "command"), detail.inspect
    refute detail.key?("approval"), "a held row carries no fact yet: #{detail.inspect}"

    # THE NOTICE: the park nudged rho's agent, which noted it
    # and dispatched nothing — the row is listed, never claimed.
    await_rho_log(/event=executor\.approval_available run_public_id=#{Regexp.escape(loop)} task=#{Regexp.escape(key)}\b/,
      "rho never noted the held call on its inbox")
    refute_includes @daemon.claimed_keys, key, "an approval row is listed, never claimed"

    # THE INBOX: one read lists both kinds; this one is kind `approval`
    # with the call and the effect profile the approver reads.
    rows = @daemon.control(:get, "/asks").fetch("asks")
    assert_equal 1, rows.length, rows.inspect
    inbox = rows.first
    assert_equal %w[approval bash], inbox.values_at("kind", "tool_name"), inbox.inspect
    assert_equal [loop, key], inbox.values_at("run_public_id", "task_key")
    assert_equal({ "command" => COMMAND }, inbox.fetch("tool_input"))
    assert_kind_of Hash, inbox.fetch("effect_profile"), "the profile the approver reads: #{inbox.inspect}"
    refute_nil inbox["deadline_at"], "a held row has a clock: #{inbox.inspect}"

    # `rho status`: the held call under `approvals:` — the row with its command and NO verb tail,
    # then ONE line naming the console (`status`, `rho approve`, and `rho deny` are CLI verbs).
    status, exit_status = @daemon.cli("status")
    assert_predicate exit_status, :success?, "rho status failed:\n#{status}"
    assert_match(/^asks:\s+\(none\)$/, status, status)
    assert_match(/^approvals:\s+1 pending$/, status, status)
    assert_match(/^#{approval_row(loop, key, COMMAND)}$/, status, "the park row prints with the command, bare:\n#{status}")
    assert_match(/^console:\s+answer and decide them on the console: `rho console`$/, status, status)
    refute_match(/rho approve|rho deny/, status, "the shipped status names no rho-dev verb:\n#{status}")

    # `rho watch` while the call stands: the ASKING line once, the park
    # line once, across the verb's own bounded polls.
    watched, = @daemon.cli("watch", loop, "--timeout", WATCH_SECONDS.to_s)
    assert_equal 1, watched.scan(/^  ASKING\s+approval_required — #{Regexp.escape(key)}$/).size,
      "the follower's ASKING line prints once:\n#{watched}"
    assert_equal 1, watched.scan(/^#{approval_line(loop, key, COMMAND)}$/).size,
      "the park line prints once while the call stands:\n#{watched}"

    # `rho task`: the held row whole, its arguments, no fact yet.
    printed, task_status = @daemon.cli("task", loop, key)
    assert_predicate task_status, :success?, "rho task failed:\n#{printed}"
    assert_match(/^task:\s+#{Regexp.escape(key)} \(tool_task\) needs_approval$/, printed, printed)
    assert_match(/^input:\s+\{"command":"#{Regexp.escape(COMMAND)}"\}$/, printed, printed)
    refute_match(/^approval:/, printed, "no fact before the decision:\n#{printed}")

    # THE GRANT, through the verb a person types.
    approved, approve_status = @daemon.cli("approve", loop, key)
    assert_predicate approve_status, :success?, "rho approve failed:\n#{approved}"
    assert_match(/^approved:\s+#{Regexp.escape(key)}$/, approved, approved)
    assert_match(/^status:\s+dispatched$/, approved, "a runner tool is released to its runner:\n#{approved}")

    completed = await_run_status(loop, "completed")
    task = completed.fetch("tasks").find { |t| t.fetch("key") == key }
    assert_equal "completed", task.fetch("status"), summarize(completed)
    fact = task.fetch("approval")
    assert_equal "agent", fact.fetch("origin"), "rho's bearer is the Agent's: #{fact.inspect}"
    assert_equal rho_user_public_id, fact.fetch("decided_by"), fact.inspect
    refute_equal @steward.public_id, fact.fetch("decided_by"), "the delegate's grant, not the person's"
    refute_nil fact["decided_at"], fact.inspect
    assert_equal "held", File.read(File.join(project, "held.txt"), encoding: Encoding::UTF_8).strip,
      "rho's runner ran the released call"

    printed, = @daemon.cli("task", loop, key)
    assert_match(/^approval:\s+agent \(#{Regexp.escape(rho_user_public_id)}\) at \S+$/, printed,
      "the fact prints who and when:\n#{printed}")
    assert_equal 1, feed(conversation).count { |item| item["type"] == "attention_required" },
      "one park, decided once"

    status, = @daemon.cli("status")
    assert_match(/^approvals:\s+\(none\)$/, status, "a decided call stands on no inbox:\n#{status}")
    watched, watch_status = @daemon.cli("watch", loop)
    assert_predicate watch_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+completed$/, watched, watched)
    refute_match(/^  approval\s/, watched, "a decided call prints no park line:\n#{watched}")
  end

  # EVOLUTION BY INCUBATION: rho refuses its OWN model's `write`/`edit` under its checkout and its
  # home, and any `bash` naming either — deny rules rho declares beside the Guard list, so the
  # kernel refuses at the stage under `bypass` as under every mode, before any runner, and the next
  # round reads the reason. The rule anchors on the RESOLVED root (macOS's `/var` is
  # `/private/var`): the journey spells the resolved path, as a model that read `rho status` or
  # `pwd` would. A write under the project beside them — outside both roots — is claimed and runs.
  def test_rho_refuses_its_own_models_write_under_its_home_and_its_checkout_before_any_runner
    project = connect!
    outside = Dir.mktmpdir("rho-approval-project")
    home = File.realpath(@home)
    checkout = File.realpath(E2E::RhoDaemon::RHO_ROOT)
    begin
      @daemon.control(:post, "/environment", body: { root: outside })

      _conversation, _turn, homed = open_turn(write_prompt(File.join(home, "settings.json"), "done"), project)
      refused = refused_call(homed, INCUBATION, tool: "write")
      refute_includes @daemon.claimed_keys, refused.fetch("key"), "the kernel refused before any runner"
      assert_includes task_output(homed, "r2"), "(approval_denied) #{INCUBATION}", "the next round read the reason"
      printed, = @daemon.cli("task", homed, refused.fetch("key"))
      assert_match(/^error:\s+approval_denied — #{Regexp.escape(INCUBATION)}$/, printed, printed)

      _conversation, _turn, shelled = open_turn(bash_prompt("echo x >> #{File.join(home, "settings.json")}", "done"), project)
      refute_includes @daemon.claimed_keys, refused_call(shelled, INCUBATION).fetch("key"), "a command naming the home is refused whole"

      _conversation, _turn, sourced = open_turn(write_prompt(File.join(checkout, "lib", "rho.rb"), "done"), project)
      refute_includes @daemon.claimed_keys, refused_call(sourced, INCUBATION, tool: "write").fetch("key"),
        "the checkout the running daemon loads from is protected too"

      note = File.join(outside, "note.txt")
      _conversation, _turn, allowed = open_turn(write_prompt(note, "done"), project)
      done = await_run_status(allowed, "completed")
      write = done.fetch("tasks").find { |t| t["tool_name"] == "write" } || flunk(summarize(done))
      assert_equal "completed", write.fetch("status"), "a write beside the roots runs: #{write.inspect}"
      assert_includes @daemon.claimed_keys, write.fetch("key"), "…on rho's own runner"
      assert_equal "x", File.read(note, encoding: Encoding::UTF_8)
    ensure
      FileUtils.remove_entry(outside) if File.directory?(outside)
    end
  end

  # THE PREFIX, THE PATH, THE WHOLE TOOL, AND THE REFUSALS: `--match printf` grants `printf *` with
  # the raw-text warning and a second printf never parks; the five derivation refusals answer their
  # sentences before anything moves and the row stays held; a parked `write` is keyed on its `path`
  # — exact, then a directory prefix — and a held row with no text key (`stop_process`) refuses
  # `--match` and is granted whole.
  def test_match_grants_a_prefix_a_path_is_keyed_on_its_path_and_the_refusals_leave_the_row_held
    project = connect!
    outside = Dir.mktmpdir("rho-approval-grant")
    begin
      _c, _t, loop = open_turn(bash_prompt(COMMAND, "done"), project, "--approval", "ask")
      key = await_park(loop).fetch("key")
      approved, approve_status = @daemon.cli("approve", loop, key, "--match", "printf")
      assert_predicate approve_status, :success?, "rho approve --match failed:\n#{approved}"
      assert_match(/^granted:   bash  command = "printf \*"   \(this session; `rho rules` lists it\)$/, approved, approved)
      assert_match(/^warning:   a prefix grant is raw text — it also allows "printf anything; …" on the same line$/,
        approved, approved)
      await_run_status(loop, "completed")

      _c, _t, second = open_turn(bash_prompt("printf other > other.txt", "done"), project, "--approval", "ask")
      done = await_run_status(second, "completed")
      call = done.fetch("tasks").find { |t| t["tool_name"] == "bash" } || flunk(summarize(done))
      assert_equal %w[completed rule], [call.fetch("status"), call.dig("approval", "origin")], summarize(done)
      assert_equal "other", File.read(File.join(project, "other.txt"), encoding: Encoding::UTF_8).strip

      # THE REFUSALS on a later park (`ls` is a command here, not the read tool).
      _c, _t, held = open_turn(bash_prompt("ls -la > listing.txt", "done"), project, "--approval", "ask")
      held_key = await_park(held).fetch("key")
      {
        ["--match", "echo"] => "--match must be a whole-token prefix of the held command, followed by \" \": \"ls -la > listing.txt\"",
        ["--match", "l"] => "--match must be a whole-token prefix of the held command, followed by \" \": \"ls -la > listing.txt\"",
        ["--match", "l*"] => "--match is literal text and cannot be blank; the kernel reads * and ? as wildcards",
        ["--match", ""] => "--match is literal text and cannot be blank; the kernel reads * and ? as wildcards",
      }.each do |flags, sentence|
        refused, refused_status = @daemon.cli("approve", held, held_key, *flags)
        refute_predicate refused_status, :success?, "#{flags.inspect} must be refused:\n#{refused}"
        assert_includes refused, "rho approve: #{sentence}", refused
      end
      assert_equal "needs_approval", task_detail(held, held_key).fetch("status"), "a refused grant moves nothing"
      _denied, = @daemon.cli("deny", held, held_key, REASON)

      _c, _t, globbed = open_turn(bash_prompt("ls *.rb", "done"), project, "--approval", "ask")
      globbed_key = await_park(globbed).fetch("key")
      refused, refused_status = @daemon.cli("approve", globbed, globbed_key, "--always")
      refute_predicate refused_status, :success?, refused
      assert_includes refused,
        "rho approve: the held command contains * or ?, which the kernel reads as wildcards; grant a prefix with --match instead"
      assert_equal "needs_approval", task_detail(globbed, globbed_key).fetch("status")
      _denied, = @daemon.cli("deny", globbed, globbed_key, REASON)

      # THE PATH: a parked `write` outside rho's own roots, keyed on `path`.
      @daemon.control(:post, "/environment", body: { root: outside })
      a = File.join(outside, "a.md")
      _c, _t, writing = open_turn(write_prompt(a, "done"), outside, "--approval", "ask")
      write_key = await_park(writing).fetch("key")
      approved, approve_status = @daemon.cli("approve", writing, write_key, "--always")
      assert_predicate approve_status, :success?, approved
      assert_match(/^granted:   write  path = "#{Regexp.escape(shown(a))}"   \(this session; `rho rules` lists it\)$/,
        approved, approved)
      await_run_status(writing, "completed")
      assert_equal "x", File.read(a, encoding: Encoding::UTF_8)

      FileUtils.rm_f(a)
      _c, _t, same = open_turn(write_prompt(a, "done"), outside, "--approval", "ask")
      done = await_run_status(same, "completed")
      write = done.fetch("tasks").find { |t| t["tool_name"] == "write" } || flunk(summarize(done))
      assert_equal %w[completed rule], [write.fetch("status"), write.dig("approval", "origin")], "the same path never parks"
      assert_equal "x", File.read(a, encoding: Encoding::UTF_8)

      b = File.join(outside, "b.md")
      _c, _t, sibling = open_turn(write_prompt(b, "done"), outside, "--approval", "ask")
      sibling_key = await_park(sibling).fetch("key")
      approved, approve_status = @daemon.cli("approve", sibling, sibling_key, "--match", outside)
      assert_predicate approve_status, :success?, approved
      assert_match(/^granted:   write  path = "#{Regexp.escape(shown("#{outside}/*"))}"   \(this session; `rho rules` lists it\)$/,
        approved, approved)
      assert_match(/^warning:   a prefix grant is raw text — it also allows "#{Regexp.escape(shown("#{outside}/"))}anything; …" on the same line$/,
        approved, approved)
      await_run_status(sibling, "completed")

      _c, _t, third = open_turn(write_prompt(File.join(outside, "c.md"), "done"), outside, "--approval", "ask")
      done = await_run_status(third, "completed")
      write = done.fetch("tasks").find { |t| t["tool_name"] == "write" } || flunk(summarize(done))
      assert_equal %w[completed rule], [write.fetch("status"), write.dig("approval", "origin")], "the directory prefix"

      # THE WHOLE TOOL: `--match` on a row with no text key refuses; `--always` grants it whole.
      _c, _t, stopping = open_turn(stop_process_prompt("p9", "done"), outside, "--approval", "ask")
      stop_key = await_park(stopping).fetch("key")
      refused, refused_status = @daemon.cli("approve", stopping, stop_key, "--match", "p")
      refute_predicate refused_status, :success?, refused
      assert_includes refused,
        "rho approve: --match narrows a text-keyed tool (bash, start_process, write, edit); stop_process is granted whole"
      approved, approve_status = @daemon.cli("approve", stopping, stop_key, "--always")
      assert_predicate approve_status, :success?, approved
      assert_match(/^granted:   stop_process$/, approved, approved)
      await_run_status(stopping, "completed")

      listed, = @daemon.cli("rules")
      assert_match(/^  1  bash   command = "printf \*"   granted \S+ on #{Regexp.escape(loop)} #{Regexp.escape(key)} \(conversation \S+\)$/, listed, listed)
      assert_match(/^  2  write  path = "#{Regexp.escape(shown(a))}"   granted /, listed, listed)
      assert_match(/^  3  write  path = "#{Regexp.escape(shown("#{outside}/*"))}"   granted /, listed, listed)
      assert_match(/^  4  stop_process   granted \S+ on #{Regexp.escape(stopping)} #{Regexp.escape(stop_key)} \(conversation \S+\)$/,
        listed, listed)
      refute_match(/^  5 /, listed, listed)
    ensure
      FileUtils.remove_entry(outside) if File.directory?(outside)
    end
  end

  private

    # THE SAME HOME, BOOTED AGAIN (the MCP journey's shape): the credentials
    # stand, no new grant; a stale announcement would answer the readiness
    # wait for a daemon that is gone, so it is cleared before the boot; the
    # conversation host is re-adopted (`runs.readopted`) and the boot's
    # own declaration has landed (`profile.declared`) before the next turn.
    def restart!
      @daemon.stop
      FileUtils.rm_f(File.join(@home, "tmp", "announcement.json"))
      readopted = log_count(/event=runs\.readopted/)
      declared = log_count(/event=profile\.declared/)
      @daemon.start
      await_workspace_state("adopted")
      @daemon.await("the conversation host was never re-adopted") do
        log_count(/event=runs\.readopted/) > readopted ? true : nil
      end
      @daemon.await("the booted daemon never declared its profile") do
        log_count(/event=profile\.declared/) > declared ? true : nil
      end
    end

    # THE ONE BOUND every model-authored matcher prints through (design
    # r2 S26; `Rho::Cli::Reporting#bounded`, `ASK_PROMPT_WIDTH` = 80): the
    # first eighty characters and an ellipsis — a tmp directory's path is
    # longer than that, so the printed grant is its bounded spelling while
    # the kernel's rule (the next turn's `origin: rule`) carries it whole.
    MATCHER_WIDTH = 80

    def shown(text) = text.length > MATCHER_WIDTH ? "#{text[0, MATCHER_WIDTH]}…" : text

    def stop_process_prompt(id, remainder)
      arguments = CGI.escape(JSON.generate({ "id" => id }))
      "!mock tool_call=stop_process tool_args=#{arguments} -- #{remainder}"
    end

    def write_prompt(path, remainder)
      arguments = CGI.escape(JSON.generate({ "path" => path, "content" => "x" }))
      "!mock tool_call=write tool_args=#{arguments} -- #{remainder}"
    end

    def bash_prompt(command, remainder)
      arguments = CGI.escape(JSON.generate({ "command" => command }))
      "!mock tool_call=bash tool_args=#{arguments} -- #{remainder}"
    end

    def ask_prompt(remainder)
      arguments = CGI.escape(JSON.generate({ "prompt" => QUESTION }))
      "!mock tool_call=ask tool_args=#{arguments} -- #{remainder}"
    end

    # The park ROW every terminal prints: `approval` padded to ten, the
    # loop, the key, the tool, the command quoted — no tail.
    def approval_row(loop, key, command)
      "  approval   #{Regexp.escape(loop)} #{Regexp.escape(key)}  bash \"#{Regexp.escape(command)}\""
    end

    # rho-dev's park LINE (`rho watch`): the row, then both verbs as hints.
    def approval_line(loop, key, command)
      "#{approval_row(loop, key, command)}" \
        "  → rho approve #{Regexp.escape(loop)} #{Regexp.escape(key)} \| rho deny #{Regexp.escape(loop)} " \
        "#{Regexp.escape(key)} \[reason\]"
    end

    # The tool row the kernel refused: `failed approval_denied` with the
    # rule's sentence as the detail and NO fact; the loop completed.
    def refused_call(loop, detail, tool: "bash")
      done = await_run_status(loop, "completed")
      calls = done.fetch("tasks").select { |t| t["kind"] == "tool_task" && t["tool_name"] == tool }
      refused = calls.find { |t| t.dig("error", "key") == "approval_denied" }
      refute_nil refused, "no #{tool} call was refused by the kernel: #{summarize(done)}"
      assert_equal "failed", refused.fetch("status"), refused.inspect
      assert_equal({ "key" => "approval_denied", "detail" => detail }, refused.fetch("error"))
      refute refused.key?("approval"), "a rule's deny stamps no fact: #{refused.inspect}"
      refused
    end

    # The trace's held call: a `tool_task` resting at `needs_approval`.
    def await_park(loop)
      await("the call never parked", every: LOOP_POLL) do
        row = loop_row(loop)
        row.fetch("tasks").find { |task| task["kind"] == "tool_task" && task["status"] == "needs_approval" }
      end
    end

    # The daemon's own row for the loop's host, once its follower has the
    # park's attention with the held keys.
    def await_followed_attention(loop)
      await("the daemon's row never carried the park", every: 1) do
        row = @daemon.control(:get, "/followers").fetch("followers").find do |candidate|
          candidate.fetch("public_id") == loop || Array(candidate["run_public_ids"]).include?(loop)
        end
        row if row && row.dig("attention", "reason") == "approval_required"
      end
    end

    # The trace's parked ask: an `await_task` in `awaiting_input`.
    def await_ask(loop)
      await("the model never asked", every: LOOP_POLL) do
        row = loop_row(loop)
        row.fetch("tasks").find { |task| task["kind"] == "await_task" && task["status"] == "awaiting_input" }
      end
    end

    # rho's member bearer resolves to the Agent user: the id the
    # daemon's identity names, and the id a `rho approve` stamps.
    def rho_user_public_id
      @rho_user_public_id ||= @daemon.status.dig("identity", "user_public_id") ||
        flunk("the daemon names no user: #{@daemon.status.inspect}")
    end

    # A few of the watch's one-second polls: enough for the park line and
    # the ASKING line, both printed on the first.
    WATCH_SECONDS = 4

    # The daemon connected and adopted, the dev lane open, the hosts up,
    # the tools pointed at a project of their own.
    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      @daemon.control(:post, "/environment", body: { root: project })
      project
    end

    # `rho do`: the conversation, its turn, and the loop backing it; the
    # extra flags are the turn's own (`--approval`, `--until`).
    def open_turn(prompt, project, *flags)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project, *flags)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def await_rho_log(pattern, message)
      @daemon.await(message) { @daemon.log_text.match?(pattern) ? true : nil }
    end

    def log_count(pattern) = @daemon.log_text.scan(pattern).length

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    # The member task read, whole: the row and its bodies.
    def task_detail(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").fetch("task")

    def task_output(loop, task_key) = task_detail(loop, task_key)["output"].to_s

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_run_status(loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

    # Paced: the member plane admits 120 loop reads a minute per caller.
    LOOP_POLL = 1
    AWAIT_SECONDS = 90

    def await(message, every:)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""}" \
          "#{task.dig("error", "key") ? " !#{task.dig("error", "key")}" : ""})"
      end.join(" ")
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    # The shared steward session (E2E::StewardSession) signed in once for
    # this file; each test lands on the dashboard and asserts it — the same
    # assertion the per-test sign-in made, now against the shared session.
    def sign_in_steward
      @actor.visit("/")
      assert @page.has_text?("Overview")
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
