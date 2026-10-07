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
require "support/thread_check"

# A MODEL'S QUESTION IS THE AGENT'S INBOX ROW (asks are inbox rows, with two doors over one
# settlement). A model's `ask` on a loop rho created is a tokenless await addressed to rho's own
# address: LISTED on its inbox with the question, never claimed, and committed on the executor plane
# WITHOUT a token — the address is the door. The person's door — the member `resolution` route,
# write standing — still answers the same row, and the second answer is `idle`.
#
# E6: the mock asks; rho's log notes the row; `rho status` lists it with
# its question and the verb that answers it; `rho watch` prints the inbox
# line once beside the follower's ASKING line; `rho answer` with no token
# commits on the executor plane; the continuation reads `<answer task=…>`;
# the member door afterwards is 200 with the task as it stands.
#
# E7: a loop a PERSON created through the member API has no declaring
# profile, so its ask is addressed to nobody: rho's inbox lists nothing,
# and `rho answer` — refused `not_addressed_here` on the executor plane —
# falls once to the member door, where rho's bearer has write standing.
#
# Driven through the shipped binary on the full default set, against the
# mock provider, which echoes what a continuation was shown.
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class AskInboxTest < Minitest::Test
  include E2E::ThreadCheck
  MODEL = "dev/mock-text".freeze
  QUESTION = "which database?".freeze
  ANSWER = "Postgres".freeze
  # The await a model's `ask` appends hangs under the call's key
  # (`AgentRuns::Asks::Run::KEY_SUFFIX`); the answer tag names the call.
  ASK_KEY = /\A(?<call>r\d+t\d+)-ask-1\z/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-ask-inbox-e2e")
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
        File.expand_path("../artifacts/screenshots/ask_inbox-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture ask inbox E2E capture: #{error.class}: #{error.message}"
  ensure
    begin
      @daemon&.stop
    rescue StandardError => error
      warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  # E6. `ask` is a kernel tool rho declares on every turn; the mock calls
  # it, `AskJob` appends the tokenless await and the scheduler addresses
  # it to rho's address — the row is rho's to list and to answer.
  def test_a_models_ask_is_the_agents_inbox_row_and_rho_answer_commits_on_the_executor_plane
    project = connect!
    conversation, _turn, loop = open_turn(ask_prompt("ask me"), project)
    ask = await_ask(loop)
    key = ask.fetch("key")
    call = ASK_KEY.match(key) { |match| match[:call] } || flunk("the ask hangs under no call key: #{key}")

    # THE DAEMON'S ASK NOTICE: the `work_available{kind: ask}` frame is
    # logged, never dispatched — the runner takes no ask row.
    await_rho_log(/event=executor\.ask_available run_public_id=#{Regexp.escape(loop)} task=#{Regexp.escape(key)}\b/,
      "rho never noted the ask on its inbox")
    refute_includes @daemon.claimed_keys, key, "an ask row is listed, never claimed"

    # `rho status`: the level-triggered read of rho's own inbox — the row, its question, and ONE
    # line naming where a person answers it: the console, the surface every install carries
    # (`status` and `rho answer` are CLI verbs).
    status, exit_status = @daemon.cli("status")
    assert_predicate exit_status, :success?, "rho status failed:\n#{status}"
    assert_match(/^asks:\s+1 pending$/, status, status)
    assert_match(/^#{ask_line(loop, key)}$/, status, "the inbox row prints with its question:\n#{status}")
    assert_match(/^console:\s+answer and decide them on the console: `rho console`$/, status, status)
    refute_match(/rho answer/, status, "the shipped status names no rho-dev verb:\n#{status}")

    # `rho watch` while the ask stands: the inbox line ONCE beside the
    # follower's own ASKING line. Bounded by the verb's own `--timeout` —
    # the loop is waiting on us, so the watch cannot end on its own; what
    # it printed across its polls is the pin, not its exit.
    watched, = @daemon.cli("watch", loop, "--timeout", WATCH_SECONDS.to_s)
    assert_equal 1, watched.scan(/^#{ask_line(loop, key)}$/).size,
      "the inbox line prints once while the ask stands:\n#{watched}"
    assert_match(/^answer:\s+rho answer #{Regexp.escape(loop)} #{Regexp.escape(key)} "…"$/, watched,
      "rho-dev's watch names the verb that answers it, under the row:\n#{watched}")
    assert_match(/^  ASKING\s+awaiting_human — #{Regexp.escape(key)}$/, watched, "the follower's own line stays:\n#{watched}")

    # THE AGENT'S DOOR: no token — the row names its addressee and that is
    # the whole authorization; the CLI says which door settled it.
    answered, answer_status = @daemon.cli("answer", loop, key, ANSWER)
    assert_predicate answer_status, :success?, "rho answer failed:\n#{answered}"
    assert_match(/^answered:\s+#{Regexp.escape(key)} \(executor plane\)$/, answered,
      "the agent application's own inbox row commits on the executor plane:\n#{answered}")

    completed = await_run_status(loop, "completed")
    tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal %w[await_task completed], [tasks.fetch(key).fetch("kind"), tasks.fetch(key).fetch("status")],
      "the ask settled on the agent's commit: #{summarize(completed)}"
    assert_equal ANSWER, task_output(loop, key), "the commit's content is the answer"
    continued = task_output(loop, "r2")
    assert_includes continued, "<answer task=\"#{call}\">#{ANSWER}</answer>",
      "the continuation read the answer under the call it answers: #{continued.inspect}"

    # THE THREAD: NO root for the ask call — its await is hidden — so the call sits among the
    # reader's calls with its face on the row, and nothing branches.
    thread = assert_thread_matches_graph!(loop)
    reader = thread.fetch("mainline").find { |row| row["key"] == "r2" } || flunk("no r2 on the thread: #{thread.inspect}")
    assert_includes reader.fetch("calls"), call, "the ask call is a call of the round that read the answer"
    assert_empty thread.fetch("branches"), "an ask is not a branch: #{thread.inspect}"

    watched, watch_status = @daemon.cli("watch", loop)
    assert_predicate watch_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^status:\s+completed$/, watched, "a settled loop's watch returns:\n#{watched}")
    refute_match(/^  ask\s/, watched, "an answered ask stands on no inbox:\n#{watched}")

    # THE PERSON'S DOOR, after the fact: the same row, one settle — the
    # second answer is `idle`, 200 with the task as it stands.
    body, code = agent_api_post("#{loop_path(loop)}/tasks/#{key}/resolution", { "content" => "MySQL" })
    assert_equal 200, code, "the member door answers the settled row idle: #{body}"
    assert_equal "completed", body.dig("task", "status"), body.inspect
    assert_equal ANSWER, task_output(loop, key), "the second door changed nothing"
    assert_equal 1, feed(conversation).count { |item| item["type"] == "attention_required" },
      "one hold, answered once — the second door re-asked nobody"
  end

  # E7. A Human-created standalone loop: the steward authors one model
  # step carrying the kernel's own `ask` bytes and the mock's call; the
  # await it appends is addressed to nobody (no declaring profile), so it
  # is no inbox row — the person's door is the only door, and `rho
  # answer` reaches it through the recorded fall-through.
  def test_a_human_created_loops_ask_is_nobodys_inbox_row_and_rho_answers_it_at_the_persons_door
    connect!
    loop = author_asking_loop!
    ask = await_ask(loop)
    key = ask.fetch("key")
    call = ASK_KEY.match(key) { |match| match[:call] } || flunk("the ask hangs under no call key: #{key}")

    status, exit_status = @daemon.cli("status")
    assert_predicate exit_status, :success?, "rho status failed:\n#{status}"
    assert_match(/^asks:\s+\(none\)$/, status, "a Human loop's ask is nobody's inbox row:\n#{status}")
    refute_match(/^  ask\s+#{Regexp.escape(loop)}/, status, status)
    refute_match(/event=executor\.ask_available run_public_id=#{Regexp.escape(loop)}/, @daemon.log_text,
      "an ask addressed to nobody nudges nobody")

    answered, answer_status = @daemon.cli("answer", loop, key, ANSWER)
    assert_predicate answer_status, :success?, "rho answer failed:\n#{answered}"
    assert_match(/^answered:\s+#{Regexp.escape(key)} \(member door\)$/, answered,
      "the executor door refused not_addressed_here and the member door answered once:\n#{answered}")

    completed = await_run_status(loop, "completed")
    tasks = completed.fetch("tasks").to_h { |task| [task.fetch("key"), task] }
    assert_equal "completed", tasks.fetch(key).fetch("status"), summarize(completed)
    assert_equal ANSWER, task_output(loop, key)
    continued = task_output(loop, completed.fetch("deliverable_task_key"))
    assert_includes continued, "<answer task=\"#{call}\">#{ANSWER}</answer>",
      "the continuation read the answer: #{continued.inspect}"
  end

  private

    def ask_prompt(remainder)
      arguments = CGI.escape(JSON.generate({ "prompt" => QUESTION }))
      "!mock tool_call=ask tool_args=#{arguments} -- #{remainder}"
    end

    # The CLI's inbox line: `ask` padded to ten, the loop, the key, the
    # question quoted.
    def ask_line(loop, key)
      "  ask        #{Regexp.escape(loop)} #{Regexp.escape(key)}  \"#{Regexp.escape(QUESTION)}\""
    end

    # The person's shape: one model step on the mock, the kernel's `ask`
    # bytes spliced verbatim from the catalog (a paraphrase is refused
    # `kernel_tool_redefined`), started at once.
    def author_asking_loop!
      catalog = agent_api("/agent_api/v1/tools").fetch("tools")
      definition = catalog.find { |tool| tool.fetch("name") == "ask" }&.fetch("definition") ||
        flunk("the catalog publishes no `ask`: #{catalog.map { |tool| tool["name"] }.inspect}")
      path = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs"
      body, status = agent_api_post(path, { "run" => {
        "steps" => [
          { "model" => { "key" => "round1", "prompt" => ask_prompt("ask"),
                         "model" => { "model" => MODEL }, "tools" => [definition] } },
        ],
        "approval_mode" => "bypass",
      } })
      assert_equal 201, status, "authoring the asking loop: #{body}"
      loop_id = body.dig("run", "public_id")
      _, started = agent_api_post("#{path}/#{loop_id}/start", {})
      assert_equal 200, started, "starting the asking loop"
      loop_id
    end

    # The trace's parked ask: an `await_task` in `awaiting_input`.
    def await_ask(loop)
      await("the model never asked", every: LOOP_POLL) do
        row = loop_row(loop)
        row.fetch("tasks").find { |task| task["kind"] == "await_task" && task["status"] == "awaiting_input" }
      end
    end

    # A few of the watch's one-second polls: enough for the inbox line
    # and the ASKING line, both printed on the first.
    WATCH_SECONDS = 4

    # The daemon connected and adopted, the dev lane open, the hosts up.
    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      project
    end

    # `rho do`: the conversation, its turn, and the loop backing it.
    def open_turn(prompt, project)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def await_rho_log(pattern, message)
      @daemon.await(message) { @daemon.log_text.match?(pattern) ? true : nil }
    end

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_output(loop, task_key) = agent_api("#{loop_path(loop)}/tasks/#{task_key}").dig("task", "output").to_s

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
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
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

    def agent_api_post(path, body)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate(body)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      text = response.body.to_s.force_encoding(Encoding::UTF_8)
      [JSON.parse(text.empty? ? "{}" : text), response.code.to_i]
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
      assert @page.has_text?("Dashboard")
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
