require "test_helper"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/acp_client"
require "support/fixture_project"
require "support/live_journey"
require "support/secret_hygiene"

# RHO AS AN ACP AGENT ON A REAL MODEL: the scripted client (`E2E::AcpClient`, the editor's role)
# drives `rho-acp --mode ask` on the floor model through one session on a project the lane owns. Two
# turns, each its own pin:
#
# THE PARK OVER THE WIRE — the person asks for a shell command; under
# `ask` the model's `bash` rests `needs_approval` on the kernel, rho's
# surface asks the editor `session/request_permission` with the three
# options, the client's policy answers `allow`, and the command RAN: the
# file it was told to write is on disk and the parked call is `completed`
# on the loop. What the kernel and the surface owe is asserted; whether
# the model reached for `bash` at all is the row's `reached` — and the
# assertion, since a park nobody asked for proves nothing.
#
# THE REACH OF A `/skill-name` PROMPT: the surface posts the prompt VERBATIM and the model holds the
# `skill` tool and the roster (`available_commands_update` lists the project's skill after the three
# surface commands). The lane measures whether the model called `skill` for that name — the reach
# count, printed on its own line and asserted at least one — and RECORDS whether the reply carried
# the skill's word (the model's conduct, never gated; the text is written once and never tuned).
#
# Paid, local, opt-in: E2E_LIVE=1 and the floor's key; one session, two
# turns, cents. `E2E_ACP_AGENT_MODEL` names the row (else the sweep's
# `E2E_LIVE_MODEL`, else the floor). Out of the graded exit lanes.
#   E2E_LIVE=1 rake live_acp_agent
class LiveAcpAgentTest < Minitest::Test
  Methods = E2E::AcpClient::Methods
  Update = Methods::SessionUpdate

  MODEL = ENV.fetch("E2E_ACP_AGENT_MODEL") { ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model } }.freeze
  RHO_ACP_ROOT = File.expand_path("../../agents/rho/rho-acp", __dir__)
  # The surface's bundle, pinned and frozen (Bundler 4 exports the lock
  # beside the Gemfile; a child naming another Gemfile names its lock).
  SURFACE_BUNDLE_ENV = {
    "BUNDLE_GEMFILE" => File.join(RHO_ACP_ROOT, "Gemfile"),
    "BUNDLE_LOCKFILE" => File.join(RHO_ACP_ROOT, "Gemfile.lock"),
    "BUNDLE_FROZEN" => "true",
  }.freeze
  SPAWN_TIMEOUT = 30
  TURN_TIMEOUT = 600
  SKILL = "release-notes".freeze
  # The word the skill's body plants: a reply that carries it read the
  # skill (recorded, never gated).
  SKILL_WORD = "RELEASE-NOTES-LOADED".freeze
  MARKER = "approved.txt".freeze
  PROJECT = {
    ".agents/skills/#{SKILL}/SKILL.md" => <<~MARKDOWN,
      ---
      name: #{SKILL}
      description: How this project writes its release notes. Use before drafting or answering about a release note.
      ---
      # Release notes

      Every release note this project publishes opens with the word #{SKILL_WORD} on a line of its own,
      then one line per change, in the past tense.
    MARKDOWN
    "README.md" => "A project with one skill.\n",
  }.freeze
  # The two prompts, written once (the bench measures them; never tuned).
  BASH_TURN = "Run a shell command that writes the single word approved into a file named #{MARKER} in the " \
              "current directory. Then reply with the word done.".freeze
  SKILL_TURN = "/#{SKILL} Draft the release note for one change: the README now says the project has one skill.".freeze

  include E2E::LiveJourney

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-acp-agent")
    @clients = []
    @scratch = Dir.mktmpdir("rho-live-acp-agent-scratch")
  end

  def teardown
    unless passed? || skipped?
      Array(@clients).each_with_index { |client, index| warn_text(client.stderr, "rho-acp ##{index} stderr") }
    end
    Array(@clients).each(&:close)
    finish_live_journey!
    [@scratch, @project].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_a_bash_under_ask_is_approved_over_the_wire_and_a_skill_prompt_reaches_the_skill_tool
    connect_and_open_lane!
    project = write_project!
    client = surface("--mode", "ask", policy: { permission: :allow })
    client.initialize_agent(timeout: SPAWN_TIMEOUT)
    id = client.send_request(Methods::SESSION_NEW, { "cwd" => project, "mcpServers" => [] })
    opened = client.await(id, timeout: TURN_TIMEOUT)
    session = opened.fetch("sessionId")
    # The cost stop's door: the conversation is the session.
    @conversation = session
    assert_equal "ask", opened.dig("modes", "currentModeId"), "the surface's default mode is the flag's"
    model_option = opened.fetch("configOptions").find { |option| option.fetch("id") == "model" }
    assert_equal MODEL, model_option.fetch("currentValue"), "the session's model is the lane's: #{model_option.inspect}"
    roster = client.await_update(session, Update::AVAILABLE_COMMANDS_UPDATE, timeout: SPAWN_TIMEOUT)
      .dig("update", "availableCommands").map { |command| command.fetch("name") }
    assert_includes roster, SKILL, "the project's skill rides the roster after the surface commands: #{roster.inspect}"

    the_park_over_the_wire(client, session, project)
    the_reach_of_the_skill_prompt(client, session)
  end

  private

    # TURN 1: the bash under ask, the client allowing.
    def the_park_over_the_wire(client, session, project)
      turn = client.prompt(session, BASH_TURN, timeout: TURN_TIMEOUT)
      asked = turn.permissions.select { |seen| seen.dig("params", "toolCall", "kind") == Methods::ToolKind::EXECUTE }
      answered = asked.map { |seen| seen.dig("answer", "outcome", "optionId") }
      loop_id = loop_of(session, turn)
      row = await_loop_completion(loop_id)
      marker = File.join(project, MARKER)
      ran = File.file?(marker) && File.read(marker, encoding: Encoding::UTF_8).strip == "approved"
      puts "--- live acp agent bash on #{MODEL}: stop=#{turn.stop_reason} asked=#{asked.length} answered=#{answered.inspect} " \
           "ran=#{ran} called=#{called(row).inspect} reply=#{turn.text.strip[0, 120].inspect}"
      report_loop!(row, reached: !asked.empty?, succeeded: turn.stop_reason == Methods::StopReason::END_TURN && ran)

      assert_equal Methods::StopReason::END_TURN, turn.stop_reason, "the turn did not end: #{summarize(row)}"
      refute_empty asked, "THE PARK: under ask the model's bash reaches the editor as session/request_permission — " \
                          "no execute request was made: #{summarize(row)}"
      assert_equal ["allow"], answered.uniq, "the client's allow was the answer to every ask"
      assert ran, "the approved command ran in the session's cwd: #{marker} #{File.file?(marker) ? "holds #{File.read(marker).inspect}" : "is absent"}"
      asked.each do |seen|
        parked_loop, key = loop_and_key(seen.dig("params", "toolCall", "toolCallId"))
        assert_equal "completed", task(parked_loop, key).fetch("status"), "the approved call completed on the kernel"
      end
    end

    # TURN 2: the `/skill-name` prompt, posted verbatim; the reach is the
    # count of `skill` calls naming it.
    def the_reach_of_the_skill_prompt(client, session)
      turn = client.prompt(session, SKILL_TURN, timeout: TURN_TIMEOUT)
      loop_id = loop_of(session, turn)
      row = await_loop_completion(loop_id)
      skill_calls = row.fetch("tasks").select { |task| task["kind"] == "tool_task" && task["tool_name"] == "skill" }
      reach = skill_calls.count { |task| task_input(loop_id, task.fetch("key"))["name"] == SKILL }
      loaded = turn.text.include?(SKILL_WORD)
      puts "--- live acp agent skill reach on #{MODEL}: #{reach} (skill calls #{skill_calls.length}, called #{called(row).inspect}); " \
           "word=#{loaded} stop=#{turn.stop_reason} reply=#{turn.text.strip[0, 160].inspect}"
      report_loop!(row, reached: reach.positive?, succeeded: loaded)

      assert_equal Methods::StopReason::END_TURN, turn.stop_reason, "the turn did not end: #{summarize(row)}"
      assert_operator reach, :>=, 1, "THE REACH: a `/#{SKILL}` prompt is posted verbatim and the model holds the `skill` " \
                                     "tool — it never called it for the name: #{summarize(row)}"
    end

    # ---- the surface ----

    # `rho-acp` under its own bundle on the lane's home, the model the lane's.
    def surface(*flags, policy: {})
      index = @clients.length
      client = E2E::AcpClient.spawn(
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho-acp", "--model", MODEL, *flags],
        env: SURFACE_BUNDLE_ENV.merge("RHO_HOME" => @home, "RHO_NEXUS_URL" => @base_url),
        chdir: RHO_ACP_ROOT, stderr: File.join(@scratch, "surface-#{index}.stderr"), policy: policy
      )
      @clients << client
      client
    end

    # THE PROJECT, outside the home (a home is a protected root, and the
    # surface refuses a cwd under one) and REALPATH'd; the daemon's root
    # moved onto it so the runner scans and announces the skill.
    def write_project!
      @project = File.realpath(Dir.mktmpdir("rho-live-acp-agent-project"))
      E2E::FixtureProject.write(File.dirname(@project), File.basename(@project), PROJECT)
      @daemon.control(:post, "/environment", body: { root: @project })
      @project
    end

    # ---- the turn's loop, off the wire and the feed ----

    # The loop a turn ran on: the one its tool calls name, else the feed's
    # `turn_status` for the turn id the reply's chunks carry.
    def loop_of(session, turn)
      named = turn.updates.select { |update| update.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR) == Update::TOOL_CALL }
        .map { |update| loop_and_key(update.fetch("toolCallId")).first }.uniq
      return named.first if named.length == 1

      chunk = turn.updates.find { |update| update.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR) == Update::AGENT_MESSAGE_CHUNK }
      refute_nil chunk, "no tool call and no chunk on the turn: #{turn.updates.map { |u| u.fetch(Methods::SESSION_UPDATE_DISCRIMINATOR) }.inspect}"
      turn_id = chunk.fetch("messageId").rpartition(":").first
      limit = monotonic + TURN_TIMEOUT
      loop do
        found = feed(session).find { |item| item["type"] == "turn_status" && item.dig("payload", "turn_public_id") == turn_id }
        return found.dig("payload", "agent_loop_public_id") if found&.dig("payload", "agent_loop_public_id")
        flunk "no loop ever backed the turn #{turn_id}" if monotonic > limit

        sleep 3
      end
    end

    # "<loop>:<key>" — the loop and the task key a tool call names.
    def loop_and_key(tool_call_id)
      loop_id, _separator, key = tool_call_id.rpartition(":")
      refute_empty loop_id, "the toolCallId names its loop: #{tool_call_id.inspect}"
      [loop_id, key]
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

    def task(loop_id, key) = agent_api("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")

    def task_input(loop_id, key) = Hash.try_convert(task(loop_id, key)["tool_input"]) || {}

    def called(row) = row.fetch("tasks").select { |task| task["kind"] == "tool_task" }.filter_map { |task| task["tool_name"] }.tally

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def warn_text(text, label)
      return if text.to_s.empty?

      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(text.scrub.lines.last(LOG_TAIL_LINES).join)}"
    end
end
