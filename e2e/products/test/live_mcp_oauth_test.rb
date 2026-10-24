require "test_helper"
require "support/live_journey"
require "support/secret_hygiene"
require "fileutils"
require "json"
require "timeout"
require "tmpdir"

# A REAL PUBLIC OAUTH MCP SERVER, logged in to ONCE by a person: the one thing the mock journey
# (`mcp_oauth`) cannot prove — that a real authorization server's discovery, registration, consent
# page, PKCE exchange and refresh meet the official gem's flow as rho-mcp drives it, and that a
# flash-tier model then reaches a tool the server described.
#
# This manual journey opens the real browser for `rho mcp login`; the operator must consent within
# five minutes. Output is streamed so the authorization URL can be opened manually if needed.
# `E2E_MCP_OAUTH_URL` selects the server, and `E2E_MCP_OAUTH_CLIENT_ID` supplies a manually
# registered client when dynamic registration is unavailable. A server requiring undisclosed scopes
# or a confidential client is an unsupported flow to report, not a reason to invent credentials or
# silently alter the request.
#
# THE TASK NAMES THE GOAL, NEVER THE TOOL (`E2E_MCP_OAUTH_GOAL`, the `live_mcp` form): the reach — a
# completed, non-error `mcp__remote__*` call — is RECORDED on the report line and not gated; the
# pins are the login, `rho mcp` connected + logged in, the loop's completion, and token-freedom: no
# access token, refresh token or authorization code on the daemon's stdout, rho's structured log,
# the verb's own output or `rho mcp`'s. ONE floor-model loop, ≈ $0.02–0.05.
#
# Paid, local, opt-in: E2E_LIVE=1 and E2E_MCP_OAUTH_URL; in the sweep's
# skip list (`LIVE_SWEEP_SKIP`) — a manual consent lane must not block the
# sweep twice for five minutes. Run once in the paid window, by hand.
class LiveMcpOauthTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  SERVER = "remote".freeze
  URL_ENV = "E2E_MCP_OAUTH_URL".freeze
  GOAL_ENV = "E2E_MCP_OAUTH_GOAL".freeze
  CLIENT_ID_ENV = "E2E_MCP_OAUTH_CLIENT_ID".freeze
  DEFAULT_GOAL = "Using the tools the remote server offers, find out what it holds for me — list what you can see " \
                 "and reply DONE with a one-line summary.".freeze
  # The verb waits five minutes for the consent (`Callback::DEFAULT_WAIT_SECONDS`)
  # and the proof connects after; the streamed run below is bounded by the whole of it.
  LOGIN_SECONDS = 360
  # A child that ignores TERM on the timeout is KILLed after this many polls of 0.2 s.
  TERMINATE_POLLS = 10
  ECHO_PREFIX = "  rho mcp login | ".freeze

  include E2E::LiveJourney

  def setup
    skip "the live OAuth lane needs #{URL_ENV} (a public OAuth MCP server's URL)" if ENV[URL_ENV].to_s.strip.empty?

    start_live_journey!(MODEL, home_prefix: "rho-live-mcp-oauth-e2e")
    @url = ENV.fetch(URL_ENV).strip
    @project = Dir.mktmpdir("rho-live-mcp-oauth-project")
    @secrets = []
    @verb_output = +""
    row = { "transport" => "http", "url" => @url, "tools" => ["*"] }
    client_id = ENV[CLIENT_ID_ENV].to_s.strip
    row["oauth"] = { "client_id" => client_id } unless client_id.empty?
    write_daemon_home!(settings: E2E::RhoDaemon.dev_settings(plugins: { "rho.mcp" => { "enabled" => true, "configuration" => { "servers" => { SERVER => row } } } }))
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_a_real_oauth_server_is_logged_in_to_once_and_a_real_model_reaches_it
    # THE LOGIN, BEFORE THE BOOT (the ordinary path): the verb in the CLI process, no daemon; the
    # real browser; the operator clicks.
    puts "\n--- live mcp oauth: `rho mcp login #{SERVER}` opens your browser — click consent within five minutes ---"
    output, status = stream_login!
    @verb_output << output
    assert_predicate status, :success?, "rho mcp login failed:\n#{E2E::SecretHygiene.redact(output)}"
    # The logged-in line may end with the OPTIONAL clause (a server that answered anonymously
    # but published its authorization server — Context7's shape; rho-mcp 84faecc3).
    assert_match(/^logged in to #{SERVER} \(issuer \S+; scope .*; \d+ tools listed; (?:refresh token held|no refresh token)\)(?: — authorization is optional here: .*)?$/,
      output, "the verb did not report a login:\n#{E2E::SecretHygiene.redact(output)}")
    remember_secrets!
    refute_empty @secrets, "the store holds no access token after the login"

    connect_and_open_lane!

    # THE DAEMON SAYS WHAT IT LOADED: connected on the stored tokens, the
    # `auth:` line logged in, the server's tools announced under the prefix.
    listed, status = @daemon.cli("runner")
    assert_predicate status, :success?, "rho runner failed:\n#{listed}"
    refute_match(/FAILED:/, listed, "an extension failed to load:\n#{listed}")
    servers, status = @daemon.cli("mcp")
    assert_predicate status, :success?, "rho mcp failed:\n#{servers}"
    assert_match(/^server:\s+#{SERVER}\s+http\s+#{Regexp.escape(@url)}\s+serves agent\s+connected\b/, servers,
      "the server is not connected on its tokens:\n#{servers}")
    assert_match(/^\s+auth:\s+oauth — logged in \(tokens issued .*; issuer \S+; scope .*; (?:refresh token held|no refresh token)(?:; optional: the server answers anonymously too)?\)$/,
      servers, "the auth line is not logged in:\n#{servers}")
    assert_match(/^\s+mcp__#{SERVER}__\S+\s+[\d,]+ bytes/, servers, "no tool was announced:\n#{servers}")

    @daemon.control(:post, "/environment", body: { root: @project })
    task = ENV.fetch(GOAL_ENV, DEFAULT_GOAL).strip
    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", @project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    run_public_id = output[/^run:\s+(\S+)/, 1]

    completed = await_loop_completion(run_public_id)
    reached = completed.fetch("tasks").select do |t|
      t.fetch("kind") == "tool_task" && t.fetch("tool_name").to_s.start_with?("mcp__#{SERVER}__") &&
        t.fetch("status") == "completed" && t.dig("result", "is_error") != true
    end
    report(completed, reached)
    report_loop!(completed, reached: !reached.empty?, succeeded: completed.fetch("status") == "completed")

    assert_equal "completed", completed.fetch("status"), "the loop did not finish: #{summarize(completed)}"

    # Check output against both the current token and every previous token observed during the
    # journey.
    remember_secrets!
    assert_token_free!(servers)
  end

  private

    def credential_path = File.join(@home, "mcp", "credentials", "#{SERVER}.json")

    # THE VERB, STREAMED: each line the verb prints is echoed to the lane's
    # terminal as it arrives — the authorization URL is on the wire before
    # the browser is tried (the verb flushes per line), so an operator whose
    # browser did not open pastes it by hand within the consent wait — while
    # the whole output and the exit status are kept for the pins. The read
    # is the blocking helper's in every other respect: `cli_background`
    # gives stdin /dev/null and merges stderr; UTF-8 by name and scrubbed.
    # LOGIN_SECONDS bounds the whole run; on the timeout the child is
    # terminated and reaped, never left on its consent wait.
    def stream_login!
      io = @daemon.cli_background("mcp", "login", SERVER)
      output = +""
      Timeout.timeout(LOGIN_SECONDS) do
        io.each_line do |line|
          text = line.dup.force_encoding(Encoding::UTF_8).scrub
          output << text
          puts "#{ECHO_PREFIX}#{text.chomp}"
          $stdout.flush
        end
      end
      io.close
      [output, $?]
    rescue Timeout::Error
      terminate!(io)
      raise
    end

    # TERM first, a bounded poll for the exit, KILL when it was ignored;
    # `close` then reaps (a no-op once the poll already did).
    def terminate!(io)
      signal!(io.pid, "TERM")
      reaped = TERMINATE_POLLS.times.any? { Process.waitpid(io.pid, Process::WNOHANG) || (sleep(0.2) && false) }
      signal!(io.pid, "KILL") unless reaped
      io.close
    rescue Errno::ECHILD
      io.close unless io.closed?
    end

    def signal!(pid, name)
      Process.kill(name, pid)
    rescue Errno::ESRCH
      nil
    end

    # The tokens as stored — read by the lane, never printed; each
    # registered for the diagnostic hygiene and kept for the negative.
    def remember_secrets!
      return unless File.file?(credential_path)

      tokens = JSON.parse(File.read(credential_path, encoding: Encoding::UTF_8))["tokens"]
      return unless tokens.is_a?(Hash)

      tokens.values_at("access_token", "refresh_token").each do |value|
        next if value.to_s.empty? || @secrets.include?(value)

        @secrets << E2E::SecretHygiene.register(value)
      end
    end

    def assert_token_free!(listed)
      surfaces = {
        "daemon.log" => File.read(@daemon.log_path, encoding: Encoding::UTF_8).scrub,
        "rho.log" => @daemon.log_text,
        "the verb's output" => @verb_output,
        "rho mcp" => listed,
      }
      surfaces.each do |name, text|
        @secrets.each { |secret| refute_includes text, secret, "#{name} carries a token (#{secret[0, 6]}…)" }
      end
    end

    def report(row, reached)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live mcp oauth ------------------------------------------"
      puts "model:   #{MODEL}"
      puts "server:  #{@url}"
      puts "status:  #{row.fetch("status")}"
      puts "rounds:  #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:   #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "reached: #{reached.empty? ? "no — recorded, not gated" : reached.map { |t| t.fetch("tool_name") }.uniq.join(" ")}"
      puts "--------------------------------------------------------------"
    end
end
