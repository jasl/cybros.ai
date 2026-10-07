require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/mock_llm/directives"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# `rho run` — THE ONE CONVERSATION VERB a product install carries: reasonix's `run` over rho's
# daemon — open, follow, deny what nobody can approve, print the answer, exit by outcome. Driven
# through the shipped binary on a PRODUCT-SHAPED home (`extensions: []` — no rho-dev, no operator
# verb) against the mock: the three output formats; the model's ask (exit 2, the loop stopped
# through the kernel); the park a non-interactive run DENIES and runs past (reasonix's letter); the
# wall-time `--timeout` on a turn holding a runner; the acceptance check's header; `rho help`
# listing `run` under Commands and refusing `do`'s flags.
#
# THE PARK'S TIGHTENING: rho has no person-rules file, and `run` carries
# no `--approval` — so the home names a fixture extension that writes
# `approval_mode: ask` onto a turn whose prompt carries `[ask]`, through
# the daemon's own `:turn_author` door (the door rho-dev's `do --approval
# ask` reaches by the flag). Every other turn runs under rho's bypass.
#
# ONE CEREMONY PER FILE (the `processes` shape): one daemon, one RHO_HOME,
# one grant; each case opens its own conversation, so the cases run in
# any order.
class RhoRunTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 90
  DENY_REASON = "rho run: non-interactive; nobody can approve".freeze
  # A turn that holds its runner for longer than the run is willing to
  # wait; the mock's own delay is clamped, so the hold is a tool call.
  SLEEP_SECONDS = 20
  TIMEOUT_SECONDS = 2
  # The deadline plus a socket's slack — never the daemon's twenty-second
  # heartbeat (design r3 M3).
  TIMEOUT_WALL_SECONDS = 12
  ASK_MARK = "[ask]".freeze
  # (iv)'s SLOW WRITER: the mock's per-chunk delay at its clamp, over a
  # reply of some twenty eighteen-byte chunks — near four seconds of
  # writing, against the sub-second gap between `run`'s open and its
  # subscription — so the deltas land on a reader the daemon holds.
  STREAM_CHUNK_DELAY = E2E::MockLLM::Directives::DEFAULT_MAX_SLOW_SECONDS
  STREAM_WORDS = "as a stream, one chunk at a time, so that a reader who joined after the open still watches " \
    "the words land delta by delta before the turn settles and the result object closes the stream; the " \
    "daemon fans each chunk to whoever it holds as it lands, and what a reader who came late missed rides " \
    "the snapshot's partial in front of the rest".freeze

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-run-e2e")
      write_product_settings!(home)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @world
    end

    # A product home: the default set and nothing of rho-dev's, plus the
    # fixture tightening (a settings-named path, as any home may name).
    def write_product_settings!(home)
      tighten = File.join(home, "tighten.rb")
      File.write(tighten, <<~RUBY, encoding: Encoding::UTF_8)
        module RhoRunTighten
          NAME = "rho.e2e_tighten"
          def self.register(api)
            api.on(:turn_author) do |draft, _ctx|
              draft.body["prompt"].to_s.include?(#{ASK_MARK.inspect}) ? draft.with(body: draft.body.merge("approval_mode" => "ask")) : draft
            end
          end
        end
      RUBY
      File.write(tighten.sub(/\.rb\z/, ".json"), JSON.generate("id" => "rho.e2e_tighten", "default_enabled" => false))
      File.write(File.join(home, "settings.json"),
        JSON.generate({ "settings_version" => 1, "plugins" => {
          "rho.e2e_tighten" => { "enabled" => true, "source" => { "kind" => "path", "path" => tighten } },
        } }), encoding: Encoding::UTF_8, perm: 0o600)
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { RhoRunTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the rho run E2E logs: #{error.class}: #{error.message}"
  end

  # (i) TEXT: the header `do` prints — `conversation:`, `turn:`, `run:`, the adaptation row — the reply's
  # words as they stream, `status: completed`, the answer, exit 0.
  def test_text_prints_the_header_the_stream_the_status_and_the_answer
    output, status = rho_run(reply_prompt("hello from run"))

    assert_predicate status, :success?, "rho run failed:\n#{output}"
    _conversation, _turn, loop = ids_of(output)
    assert_match(/^adaptations:\s+default \(gem\)$/, output, output)
    assert_match(/^  │ Mock: hello from run/, output, "the reply streams as it is written:\n#{output}")
    assert_match(/^status:    completed$/, output, output)
    assert_match(/^status:    completed\n\nMock: hello from run/, output, "the answer follows the status:\n#{output}")
    assert_equal "completed", loop_row(loop).fetch("status")
  end

  # (ii) `-p`: the answer alone.
  def test_print_prints_the_answer_alone
    output, status = rho_run(reply_prompt("just the answer"), "-p")

    assert_predicate status, :success?, "rho run -p failed:\n#{output}"
    assert_equal ["Mock: just the answer"], output.lines.map(&:chomp).reject(&:empty?), output
  end

  # (iii) JSON: one object — `type=result subtype=success is_error=false
  # status=completed denied_calls=0`, the three ids, a duration, the answer.
  def test_json_prints_one_result_object
    output, status = rho_run(reply_prompt("as json"), "--output-format", "json")

    assert_predicate status, :success?, "rho run --output-format json failed:\n#{output}"
    object = JSON.parse(output)
    assert_equal %w[result success completed], object.values_at("type", "subtype", "status"), object.inspect
    assert_equal false, object.fetch("is_error")
    assert_equal 0, object.fetch("denied_calls")
    assert_nil object.fetch("reason")
    assert_operator object.fetch("duration_ms"), :>, 0
    %w[conversation_id turn_id run_id].each { |key| refute_nil object[key], "#{key} rides the object: #{object.inspect}" }
    assert_equal "completed", loop_row(object.fetch("run_id")).fetch("status")
    assert_match(/\AMock: as json/, object.fetch("result"), object.inspect)
  end

  # (iv) STREAM-JSON: every line parses; the first is the daemon's
  # `snapshot`, a `text_delta` rides among them, the last is the result.
  # THE DELTA IS EARNED, NOT ASSUMED: a `text_delta` reaches only a reader
  # the daemon already holds when the delta lands (`host_run.rb`
  # `stream_delta` → `notify`; the settle fans only the REMAINDER it never
  # streamed), and `run` subscribes after its own open (it needs the
  # conversation's id) — an instant mock reply lands whole inside that
  # gap, and the join-time `snapshot` carries it with no delta after (the
  # 2026-09-17 gate's frames: snapshot, round, task_status, round_result,
  # usage, turn_status ×2, closed). So the mock is told to WRITE SLOWLY
  # (`STREAM_CHUNK_DELAY` over `STREAM_WORDS`, as `streaming_test` does
  # at the kernel), the run is in before the words are out, and the
  # partial the snapshot carries plus the deltas join into the reply.
  def test_stream_json_prints_every_frame_then_the_result
    output, status = rho_run(
      "!mock stream_chunk_delay=#{STREAM_CHUNK_DELAY} reply=#{CGI.escape(STREAM_WORDS)} -- say it",
      "--output-format", "stream-json"
    )

    assert_predicate status, :success?, "rho run --output-format stream-json failed:\n#{output}"
    lines = output.lines.map { |line| JSON.parse(line) }
    types = lines.map { |line| line["type"] }
    assert_equal "snapshot", lines.first.fetch("type"), lines.first.inspect
    deltas = lines.select { |line| line["type"] == "text_delta" }
    refute_empty deltas, "no delta reached the run while the mock wrote: #{types.inspect}"
    streamed = lines.first["text"].to_s + deltas.map { |line| line["text"].to_s }.join
    assert_equal "Mock: #{STREAM_WORDS}", streamed.strip, "the partial and the deltas join into the reply: #{types.inspect}"
    assert_equal %w[result success], lines.last.values_at("type", "subtype"), lines.last.inspect
    assert_match(/\AMock: as a stream/, lines.last.fetch("result"))
  end

  # (v) THE MODEL'S ASK: nothing to deny — exit 2, the sentence names the
  # key, and the run STOPPED the loop it opened (canceled on the kernel);
  # in json the object carries it and no human line is printed.
  def test_the_models_ask_exits_2_and_the_run_stops_the_loop
    output, status = rho_run(ask_prompt("ask me"))

    assert_equal 2, status.exitstatus, "rho run on an ask must exit 2:\n#{output}"
    _conversation, _turn, loop = ids_of(output)
    assert_match(/^  ASKING     awaiting_human — (\S+)$/, output, output)
    assert_match(/^rho run: needs a person \(awaiting_human — \S+\); the run stopped it$/, output, output)
    assert_equal "canceled", await_run_status(loop, "canceled").fetch("status")

    output, status = rho_run(ask_prompt("ask again"), "--output-format", "json")
    assert_equal 2, status.exitstatus, output
    object = JSON.parse(output)
    assert_equal %w[result needs_person awaiting_human], object.values_at("type", "subtype", "reason"), object.inspect
    assert_equal true, object.fetch("is_error")
    assert_equal "canceled", await_run_status(object.fetch("run_id"), "canceled").fetch("status")
  end

  # (vi) THE PARK: under the fixture's `ask` tightening the mock's `bash`
  # rests at `needs_approval`; the run DENIES it with its reason and runs
  # on — the model reads the refusal and ends its turn — so the exit is
  # the turn's (0), `denied_calls` counts it, and the row on the kernel
  # is `failed approval_denied` with the run's sentence.
  def test_a_park_is_denied_and_the_run_continues
    output, status = rho_run(bash_prompt("printf held > held.txt", "#{ASK_MARK} then say done"))

    assert_predicate status, :success?, "rho run past a park must exit by the turn:\n#{output}"
    _conversation, _turn, loop = ids_of(output)
    assert_match(/^  ASKING     approval_required — (\S+)$/, output, output)
    key = output[/^  REFUSED (\S+) — non-interactive run$/, 1]
    refute_nil key, "the run never refused the parked call:\n#{output}"
    assert_match(/^status:    completed$/, output, output)
    refute_path_exists File.join(project, "held.txt"), "a denied call never reached the runner"
    task = task_detail(loop, key)
    assert_equal "failed", task.fetch("status"), task.inspect
    assert_equal({ "key" => "approval_denied", "detail" => DENY_REASON }, task.fetch("error"))

    output, status = rho_run(bash_prompt("printf held > held.txt", "#{ASK_MARK} again"), "--output-format", "json")
    assert_predicate status, :success?, output
    object = JSON.parse(output)
    assert_equal %w[success completed 1], object.values_at("subtype", "status", "denied_calls").map(&:to_s), object.inspect
  end

  # (vii) `--timeout`: a turn holding its runner for twenty seconds under
  # a two-second deadline exits 2 `timeout` within the deadline and a
  # socket's slack — the socket's own clock, never the heartbeat's — and
  # the loop is stopped.
  def test_timeout_exits_2_within_its_budget_and_stops_the_loop
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, status = rho_run(bash_prompt("sleep #{SLEEP_SECONDS}", "wait, then report"),
      "--timeout", TIMEOUT_SECONDS.to_s, "--output-format", "json")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 2, status.exitstatus, "rho run --timeout must exit 2:\n#{output}"
    assert_operator elapsed, :<, TIMEOUT_WALL_SECONDS, "the run took #{elapsed.round(1)} s against a #{TIMEOUT_SECONDS} s deadline"
    object = JSON.parse(output)
    assert_equal %w[timeout timeout], object.values_at("subtype", "reason"), object.inspect
    assert_equal "canceled", await_run_status(object.fetch("run_id"), "canceled").fetch("status")
  end

  # (viii) THE ACCEPTANCE CHECK rides `run` as it rode `do`: the `until:`
  # header line, and a check that passes completes the turn.
  def test_until_prints_its_header_and_a_passing_check_completes
    output, status = rho_run(reply_prompt("checked"), "--until", "true", "--attempts", "1")

    assert_predicate status, :success?, "rho run --until failed:\n#{output}"
    _conversation, _turn, loop = ids_of(output)
    assert_match(/^until:\s+true \(1 checks, in #{Regexp.escape(project)}\)$/, output, output)
    assert_match(/^status:    completed$/, output, output)
    assert_equal "completed", loop_row(loop).fetch("status")
    check = task_detail(loop, "check-1")
    assert_equal "completed", check.fetch("status"), check.inspect
    assert_equal 0, check.dig("structured_content", "exit_status"), "the acceptance check actually passed: #{check.inspect}"
  end

  # (ix) `rho help` on the product home lists `run` under Commands and
  # under no extension; `do`'s flags are refused on `run` as Thor's usage
  # error, exit 1, nothing opened.
  def test_help_lists_run_under_commands_and_run_refuses_dos_flags
    helped, status = @daemon.cli("help")
    assert_predicate status, :success?, helped
    core, *extensions = helped.split(/^Extension /)
    assert_match(/^\s+rho run \[PROMPT\]\s+#/, core, "`run` is a core verb:\n#{helped}")
    extensions.each { |section| refute_match(/^\s+rho run\b/, section, "`run` is under no extension:\n#{section}") }

    output, status = @daemon.cli("run", "hello", "--approval", "ask")
    assert_equal 1, status.exitstatus, output
    assert_match(/was called with arguments \["hello", "--approval", "ask"\]/, output, output)
    assert_match(/Usage: "rho run \[PROMPT\]"/, output, output)
  end

  private

    # THE SHIPPED BINARY, the one verb: the prompt, the model, the project.
    def rho_run(prompt, *flags)
      @daemon.cli("run", prompt, "--model", MODEL, "--dir", project, *flags)
    end

    def ids_of(output)
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho run printed fewer than three ids:\n#{output}"
      ids
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # The fake speaks the given words instead of its echo (`reply=`).
    def reply_prompt(words) = "!mock reply=#{CGI.escape(words)} -- say it"

    def ask_prompt(remainder)
      arguments = CGI.escape(JSON.generate({ "prompt" => "which database?" }))
      "!mock tool_call=ask tool_args=#{arguments} -- #{remainder}"
    end

    def bash_prompt(command, remainder)
      arguments = CGI.escape(JSON.generate({ "command" => command }))
      "!mock tool_call=bash tool_args=#{arguments} -- #{remainder}"
    end

    # ---- the kernel, as the steward reads it ----

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_detail(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").fetch("task")

    def await_run_status(loop, status)
      await("the loop #{loop} never reached #{status}", every: POLL) do
        row = loop_row(loop)
        row if row["status"] == status
      end
    end

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

    # The MEMBER plane, as the person who owns the work. UTF-8 by name.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def warn_log(path, label)
      return unless path && File.file?(path)

      warn "---- #{label} (#{path}) ----"
      warn E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8).lines.last(80).join)
    end
end
