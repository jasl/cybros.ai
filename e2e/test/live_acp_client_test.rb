require "test_helper"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "rho/acp-client"
require "support/fixture_project"
require "support/live_journey"
require "support/rho_daemon"
require "support/secret_hygiene"

# RHO AS AN ACP CLIENT OF CODEX, UNDER THE OWNER'S LOGIN (codex under its existing login): the floor
# model is told to hand a two-file edit to the `codex` row through `delegate_agent`, and the row is
# codex-acp as configured here — `npx -y @agentclientprotocol/codex-acp@ 1.12.0`, `env` `CODEX_HOME`
# (the real one), `NO_BROWSER=1` (no browser login is offered: the api-key method alone),
# `INITIAL_AGENT_MODE= read-only` ("ask for approval": reviewer user, workspace-write sandbox,
# network off — the default `agent` mode routes approvals to Codex's own auto-review sub-agent
# before rho's floor sees them), `model` the base id `gpt-6-astra` (set through
# `session/set_config_option` on the child's `category: "model"` option). Codex asks permission only
# for sandbox escapes: in-workspace edits never reach the floor.
#
# WHAT THE LANE PINS: (a) THE ENVIRONMENT — the row's `env` is exactly
# the three names, and the child's environment as the client computes it
# (`Rho::AcpClient.child_env`: the runner's scrub plus the row's env,
# REPLACED at the spawn under `unsetenv_others`) carries PATH and HOME and
# the three, and no credential-shaped, `RHO_*` or Bundler name — the
# floor's own provider key never reaches codex; (b) NO `authenticate` on
# the wire — the login is Codex's own, read from `CODEX_HOME`; (c) the
# adapter's `_auth/status_update` extension reported `{authStatus: {kind:
# "account"}}` — the ChatGPT login, not an api key or a gateway; (d) the
# row's model was set; (e) the delegation ENDED (`end_turn`) and the
# conversation's end released the child with `session/close`; (f) THE
# THREAD DELETED at the end: codex-acp's `session/close` only unsubscribes
# (its `session/delete` would archive), so the lane removes the rollout
# files named by the thread id — the child's session id — under
# `CODEX_HOME/sessions` and `archived_sessions`, and nothing of it stays.
# The two-file edit itself is the model's and Codex's conduct: recorded
# as `task_pass`, never gated. The floor's permission decisions (the
# capture's notes) and a REDACTED copy of the capture are the evidence,
# saved under e2e/tmp/live_acp_client/.
#
# REDACTION: JWTs and the account are redacted in every artifact the lane
# records — every JWT-shaped string the capture carries and the account's
# email off the status update are registered with `SecretHygiene` (so the
# log dumps on a red run are clean too), and the printed row, the evidence
# copy and every failure message pass `redacted`.
#
# Paid, local, opt-in: E2E_LIVE=1 and the floor's key; the owner's Codex
# quota for the child's turn; `npx` on PATH. SKIPS, never fails, without
# a login: `CODEX_HOME/auth.json` absent. Out of the sweep (the login is
# this machine's, not a floor row's).
# Select the child's available model through E2E_ACP_CODEX_MODEL.
#   E2E_LIVE=1 E2E_ACP_CODEX_MODEL=<model-id> rake live_acp_client
class LiveAcpClientTest < Minitest::Test
  MODEL = ENV.fetch("E2E_ACP_CLIENT_MODEL") { ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model } }.freeze
  AGENT = "codex".freeze
  CODEX_ACP = "@agentclientprotocol/codex-acp@1.12.0".freeze
  CODEX_MODEL = ENV.fetch("E2E_ACP_CODEX_MODEL", "").freeze
  CODEX_HOME = File.expand_path(ENV.fetch("CODEX_HOME", "~/.codex")).freeze
  AUTH_FILE = File.join(CODEX_HOME, "auth.json").freeze
  ROW_ENV = { "CODEX_HOME" => CODEX_HOME, "NO_BROWSER" => "1", "INITIAL_AGENT_MODE" => "read-only" }.freeze
  # Explicit environment passed to the child in addition to the launcher's scrubbed baseline.
  HANDED = %w[PATH HOME].freeze + ROW_ENV.keys
  TIMEOUT_MS = 600_000
  EVIDENCE_DIR = File.expand_path("../tmp/live_acp_client", __dir__)
  TRAILER = /session: (acp-[0-9a-f]{12}) · stop: (\w+) · calls: (\d+) \((\d+) refused by the floor\) · capture: (\S+)/
  # A JWT's three base64url segments; an OpenAI account or organization id.
  JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/
  ACCOUNT_ID = /\b(?:user|org|acct)[-_][A-Za-z0-9]{12,}\b/
  PROJECT = {
    "lib/greet.rb" => "module Greet\n  def self.call(name) = name\nend\n",
    "lib/farewell.rb" => "module Farewell\n  def self.call(name) = name\nend\n",
    "README.md" => "Two one-line modules; each returns its argument unchanged.\n",
  }.freeze
  EDITED = %w[lib/greet.rb lib/farewell.rb].freeze
  # The one prompt, written once (never tuned): the whole task goes to codex.
  TASK = "Hand this whole task to the codex agent with delegate_agent and do not edit any file yourself. The task " \
         "for it: in this project, change lib/greet.rb so that Greet.call(name) returns \"Hello, \#{name}!\" and " \
         "lib/farewell.rb so that Farewell.call(name) returns \"Goodbye, \#{name}!\" — both files, the exact " \
         "strings, nothing else. Give it the two file paths and the two strings. When it answers, reply with " \
         "the word done.".freeze

  include E2E::LiveJourney

  def setup
    skip "set E2E_ACP_CODEX_MODEL to an available Codex model" if CODEX_MODEL.empty?
    start_live_journey!(MODEL, home_prefix: "rho-live-acp-client")
    skip "no Codex login: #{AUTH_FILE} is absent — `codex login` on this machine first (the live client " \
         "lane runs under the owner's login)" unless File.file?(AUTH_FILE)
    skip "npx is not on PATH: codex-acp is launched as `npx -y #{CODEX_ACP}`" unless command?("npx")
    write_daemon_home!(settings: E2E::RhoDaemon::DEV_SETTINGS.merge(
      "extensions" => ["rho/acp-client", "rho/dev"], "acp_agents" => { AGENT => row }
    ))
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_the_floor_model_delegates_a_two_file_edit_to_codex_under_the_owners_login
    connect_and_open_lane!
    project = write_project!
    the_row_and_the_scrub!
    conversation, _turn, loop_id = open_turn(TASK, project)
    @conversation = conversation
    watched, status = rho_watch(loop_id, "--timeout", LOOP_DEADLINE_SECONDS.to_s)
    assert_predicate status, :success?, redacted(watched)
    done = await_loop_completion(loop_id)
    delegation = done.fetch("tasks").find { |task| task["tool_name"] == "delegate_agent" }
    output = delegation ? task_output(loop_id, delegation.fetch("key")) : ""
    session, stop, calls, refused, capture_path = delegation ? trailer(output) : []
    # The child's own session id — Codex's thread id — off the row before
    # the release takes the row with the child.
    thread = session && acp_session(session)&.fetch("acp_session")
    closed = session ? released_with_close?(conversation, capture_path) : false
    lines = capture_path ? capture_lines(capture_path) : []
    register_secrets!(capture_path, lines)
    evidence = capture_path && record_evidence!(capture_path, session)
    authenticated = lines.any? { |line| line["dir"] == "out" && line.dig("message", "method") == "authenticate" }
    status_update = lines.find { |line| line["dir"] == "in" && line.dig("message", "method") == "_auth/status_update" }
    auth_kind = status_update&.dig("message", "params", "authStatus", "kind")
    model_set = lines.find { |line| line["dir"] == "out" && line.dig("message", "method") == "session/set_config_option" }
      &.dig("message", "params", "value")
    decisions = lines.select { |line| line["dir"] == "note" && line["event"] == "permission" }
      .map { |note| note.values_at("kind", "decision", "by", "reason") }
    edited = EDITED.select { |path| File.read(File.join(project, path), encoding: Encoding::UTF_8) != PROJECT.fetch(path) }
    removed = thread ? delete_thread!(thread) : []
    record = {
      "pass" => !delegation.nil? && stop == "end_turn" && !authenticated && auth_kind == "account" && closed && thread_files(thread).empty?,
      "reached" => !delegation.nil?, "stop" => stop, "calls" => calls, "refused" => refused,
      "authenticated" => authenticated, "auth_kind" => auth_kind, "model_set" => model_set,
      "decisions" => decisions, "edited" => edited, "closed" => closed, "thread_files_removed" => removed.length,
      "jwt_on_the_wire" => (capture_path ? File.read(capture_path, encoding: Encoding::UTF_8).match?(JWT) : nil),
      "evidence" => evidence, "reply" => output.lines.first.to_s.strip[0, 200],
    }
    puts "--- live acp client on #{MODEL}: #{record["pass"] ? "PASS" : "FAIL"} #{redacted(record.to_json)}"
    report_loop!(done, reached: !delegation.nil?, succeeded: !delegation.nil? && stop == "end_turn", task_pass: edited.sort == EDITED.sort)

    refute_nil delegation, "the floor model never reached for delegate_agent: #{summarize(done)}"
    assert_equal "end_turn", stop, "the delegation did not finish:\n#{redacted(output)}"
    refute authenticated, "no `authenticate` is sent under the login: the login is Codex's own"
    assert_equal "account", auth_kind, "codex-acp reports the ChatGPT login as kind account: #{redacted(status_update.inspect)}"
    assert_equal CODEX_MODEL, model_set, "the row's model was set through session/set_config_option"
    assert closed, "the conversation's end released the child with session/close"
    assert_empty thread_files(thread), "the thread's files are gone from #{CODEX_HOME}"
  end

  private

    # THE ROW, as `settings.json#acp_agents` carries it.
    def row
      { "command" => "npx", "args" => ["-y", CODEX_ACP], "env" => ROW_ENV, "model" => CODEX_MODEL, "timeout_ms" => TIMEOUT_MS,
        "description" => "Codex, OpenAI's coding agent, under this machine's ChatGPT login; hand it a whole coding " \
                         "task with the file paths" }
    end

    # (a) THE ENVIRONMENT, as the client computes it: the runner's scrub of
    # this process's own environment (`ChildEnv.scrubbed` reads Bundler's
    # original) plus the row's env — the same function the daemon runs.
    def the_row_and_the_scrub!
      parsed = Rho::AcpClient::Settings.parse({ AGENT => row }).fetch(0)
      refute parsed.fault?, "the row is refused: #{parsed.respond_to?(:sentence) ? parsed.sentence : parsed.inspect}"
      assert_equal ROW_ENV.keys, parsed.env.keys, "the row hands exactly the three names"
      assert_equal CODEX_MODEL, parsed.model
      handed = Rho::AcpClient.child_env(parsed, ENV.to_h.merge(E2E::RhoDaemon::CHILD_BUNDLE_ENV).merge("RHO_HOME" => @home))
      HANDED.each { |name| assert handed.key?(name), "#{name} reaches codex: #{handed.keys.sort.inspect}" }
      assert_equal ROW_ENV.values, handed.values_at(*ROW_ENV.keys)
      leaked = handed.keys.select do |name|
        name.match?(Rho::Runner::Secrets::CREDENTIAL_SHAPED) || name.start_with?("RHO_", "BUNDLE_", "BUNDLER_") ||
          name.match?(Rho::Runner::ChildEnv::BUNDLER_KEYS)
      end
      assert_empty leaked, "the scrub hands codex no credential-shaped, rho or Bundler name"
      refute handed.key?(@live_key_name), "the floor's own provider key never reaches codex"
      served = client.executors.show(runner_id).served_tools.map(&:name)
      assert_includes served, "delegate_agent", "the row put the tool on rho's runner: #{served.inspect}"
    end

    # (e) THE RELEASE: the conversation archived through the SDK →
    # `:host_ended` → the child's sessions closed on a thread of the
    # table's, the child gone; the capture (read by its path: the row
    # leaves the table with the child) then carries the `session/close`
    # — awaited, since the rows go before the ladder runs — and Codex's
    # `{}` when it answered inside the client's bound.
    def released_with_close?(conversation, capture_path)
      client.workspace(workspace_public_id).conversations.conversation(conversation).archive
      @daemon.await("the conversation's end never reached the client's table") do
        @daemon.log_text.match(/event=acp\.host_ended conversation=#{Regexp.escape(conversation)} children=1/)
      end
      @daemon.await("the child outlived its conversation") do
        @daemon.control(:get, "/acp").fetch("sessions").none? { |row| row["conversation"] == conversation } ? true : nil
      end
      close = @daemon.await("the release never sent session/close") do
        capture_lines(capture_path).find { |line| line["dir"] == "out" && line.dig("message", "method") == "session/close" }
      end
      answered = capture_lines(capture_path).any? do |line|
        line["dir"] == "in" && line.dig("message", "id") == close.dig("message", "id") && line["message"].key?("result")
      end
      puts "--- live acp client release: session/close sent, answered=#{answered}"
      true
    end

    # (f) THE THREAD'S FILES: Codex's rollouts under `sessions/` (and an
    # archived copy under `archived_sessions/`) are named by the thread
    # id; only the lane's own thread is touched.
    def thread_files(thread)
      return [] if thread.to_s.empty?

      Dir.glob(File.join(CODEX_HOME, "{sessions,archived_sessions}", "**", "*#{thread}*"))
    end

    def delete_thread!(thread)
      thread_files(thread).each { |path| FileUtils.rm_f(path) }
    end

    # ---- the evidence, redacted ----

    # Every JWT the capture carries and the account's email are secrets
    # from here on: `SecretHygiene.redact` erases them from the log dumps
    # and from everything `redacted` prints.
    def register_secrets!(capture_path, lines)
      return if capture_path.nil?

      File.read(capture_path, encoding: Encoding::UTF_8).scan(JWT).uniq.each { |token| E2E::SecretHygiene.register(token) }
      lines.select { |line| line.dig("message", "method") == "_auth/status_update" }.each do |line|
        email = line.dig("message", "params", "authStatus", "account", "email")
        E2E::SecretHygiene.register(email) if email.is_a?(String) && !email.empty?
      end
    end

    def redacted(text)
      E2E::SecretHygiene.redact(text.to_s.gsub(JWT, "[JWT]").gsub(ACCOUNT_ID, "[ACCOUNT]"))
    end

    # A redacted copy of the capture, kept past the home's removal.
    def record_evidence!(capture_path, session)
      FileUtils.mkdir_p(EVIDENCE_DIR)
      path = File.join(EVIDENCE_DIR, "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{session}.jsonl")
      File.write(path, redacted(File.read(capture_path, encoding: Encoding::UTF_8)), encoding: Encoding::UTF_8)
      path
    end

    # ---- the daemon, the capture, the kernel ----

    def client
      @client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    def runner_id
      @daemon.status.dig("identity", "runner_executor_public_id") || flunk("a full-mode rho registers a runner row: #{@daemon.status.inspect}")
    end

    def acp_session(session)
      @daemon.control(:get, "/acp").fetch("sessions").find { |row| row["session"] == session }
    end

    def capture_lines(path)
      File.read(path, encoding: Encoding::UTF_8).lines.map { |line| JSON.parse(line) }
    end

    def trailer(output)
      match = output.match(TRAILER)
      refute_nil match, "no trailer line:\n#{redacted(output)}"
      match.captures
    end

    # THE PROJECT, outside the home: rho's floor refuses a path under
    # `$RHO_HOME` to any child, and Codex's sandbox is its cwd.
    def write_project!
      @project = File.realpath(Dir.mktmpdir("rho-live-acp-client-project"))
      E2E::FixtureProject.write(File.dirname(@project), File.basename(@project), PROJECT)
      @daemon.control(:post, "/environment", body: { root: @project })
      @project
    end

    def open_turn(prompt, project)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{redacted(output)}"
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{redacted(output)}"
      ids
    end

    def task_output(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")["output"].to_s

    def command?(name) = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
end
