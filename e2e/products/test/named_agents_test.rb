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

# Role publication references a reusable Preset without creating a User.
# These journeys use rho's public controls and real model/tool execution to
# verify captured role configuration; peer messaging has its own rho_spawn lane.
class SubagentRolesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  OTHER_MODEL = "dev/mock-text-only".freeze
  POLL = 0.2
  AWAIT_SECONDS = E2E::RhoDaemon::WATCH_TIMEOUT
  NOTE_LINE = "The role project has one note.".freeze
  REVIEWER_BODY = "Review only the supplied task and report concrete findings.\n".freeze
  REVIEWER = <<~MD.freeze
    ---
    name: e2e-review
    description: Review a supplied change.
    tools: []
    runner_tool_names: read
    model: #{OTHER_MODEL}
    ---
    #{REVIEWER_BODY.chomp}
  MD
  World = Struct.new(:daemon, :home, :root, :steward, :room_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      E2E.enable_dev_lane!
      client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room = client.workspaces.create(name: "Subagent roles #{SecureRandom.hex(3)}", access_mode: "account_wide",
        idempotency_key: SecureRandom.uuid).workspace.public_id
      home = Dir.mktmpdir("rho-roles-e2e")
      root = Dir.mktmpdir("rho-roles-root")
      File.write(File.join(root, "NOTES.md"), "#{NOTE_LINE}\n", encoding: Encoding::UTF_8)
      File.write(File.join(home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(default_model: MODEL)), perm: 0o600)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room }, tools_root: root)
      @world = World.new(daemon: daemon, home: home, root: root, steward: steward, room_public_id: room)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      daemon.await("rho never adopted the role workspace") do
        workspace = daemon.status["workspace"]
        workspace if workspace && workspace["state"] == "adopted" && workspace["public_id"] == room
      end
      daemon.await_announced(address: "runner")
      E2E.hosts.start
      @world
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      world.daemon.stop
      [world.home, world.root].each { |directory| FileUtils.remove_entry(directory) if File.directory?(directory) }
    end
  end

  Minitest.after_run { SubagentRolesTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
    @preset_ids = presets.map { |row| row.fetch("public_id") }
  end

  def teardown
    return if @daemon.nil? || @preset_ids.nil?

    unless passed?
      warn_log(@daemon&.log_path, "rho stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      %i[runner jobs].each { |host| warn_log(E2E.hosts.log_path(host), "Nexus #{host}") }
    end
    presets.reject { |row| @preset_ids.include?(row.fetch("public_id")) }.each do |row|
      @daemon.control(:post, "/presets/rm", body: { "public_id" => row.fetch("public_id") })
    end
  end

  def test_importing_and_publishing_a_preset_creates_no_identity_and_spawns_with_its_tools
    identities = principal_ids
    @daemon.write_definition("e2e-review", REVIEWER)
    imported = @daemon.control(:post, "/presets/import", body: { "names" => ["e2e-review"] })
    assert_empty imported.fetch("skipped")
    preset = imported.fetch("imported").find { |row| row.fetch("name") == "e2e-review" }
    refute_nil preset
    assert_equal REVIEWER_BODY, preset.dig("configuration", "system_prompt")
    assert_equal [], preset.dig("configuration", "tools")
    assert_equal ["read"], preset.dig("configuration", "runner_tool_names")
    assert_nil preset.fetch("role")
    assert_equal identities, principal_ids
    publish(preset, "e2e-review", "Review a completed change for defects.")
    @daemon.delete_definition("e2e-review")
    assert_equal preset.fetch("configuration"), find_preset(preset).fetch("configuration"), "the file is no longer a live configuration owner"

    claims = @daemon.claims.length
    brief = script([["read", { "path" => "NOTES.md" }]], "review complete")
    conversation, _turn, parent = rho_do(script([["spawn", { "role" => "e2e-review", "prompt" => brief, "wait" => true, "label" => "review" }]], "received review"))
    await_run_status(parent, "completed")
    child = await_child(conversation, "review")
    assert_equal @conversations.conversation(conversation).fetch.answering_user_public_id, child.answering_user_public_id
    reply = await_reply(child.public_id)
    child_run = reply.active_variant.run_public_id
    assert_equal OTHER_MODEL, loop_row(child_run).dig("turn", "model", "model")
    assert_includes sealed_texts(child_run, "r1").join("\n"), REVIEWER_BODY
    assert_includes task_result(child_run, "r2t0"), NOTE_LINE
    tools = agent_api("#{loop_path(child_run)}/tasks/r1").fetch("task").fetch("tool_definitions")
    assert_equal ["read"], tools.map { |tool| tool.dig("function", "name") }
    assert_equal @daemon.status.dig("identity", "runner_executor_public_id"), @conversations.conversation(child.public_id).fetch.default_runner&.executor_public_id
    assert_equal claims + 1, @daemon.claims.length
    request = agent_api("#{loop_path(parent)}/tasks/r2/request").fetch("request")
    assert_includes JSON.generate(request.fetch("entries")), "review complete"
    assert_equal identities, principal_ids, "role publication and execution never mint a standing User"
  ensure
    @daemon.delete_definition("e2e-review")
  end

  def test_role_changes_and_withdrawal_affect_future_work_while_the_accepted_directory_stays_captured
    identities = principal_ids
    preset = create_preset("capture", system_prompt: "CAPTURED-ROLE-PROMPT", model: OTHER_MODEL, runner_tool_names: [])
    role = "capture-#{SecureRandom.hex(3)}"
    publish(preset, role, "Use the original role configuration.")
    brief = script([["ask", { "prompt" => "Continue the captured child?" }]], "captured child finished")
    conversation, _turn, parent = rho_do(script([
      ["ask", { "prompt" => "Release the captured directory?" }],
      ["spawn", { "role" => role, "prompt" => brief, "label" => "captured" }],
    ], "delegated"))
    pending = await_ask(parent)
    assert_includes sealed_texts(parent, "r1").join("\n"), "Use the original role configuration."
    replace_preset(preset, system_prompt: "UPDATED-ROLE-PROMPT", model: MODEL)
    @daemon.control(:delete, "/presets/role", body: { "public_id" => preset.fetch("public_id") })
    assert_nil find_preset(preset).fetch("role")
    answer(pending)
    child = await_child(conversation, "captured")
    child_pending = await_ask(nil, prompt: "Continue the captured child?")
    child_run = child_pending.fetch("run_public_id")
    assert_equal OTHER_MODEL, loop_row(child_run).dig("turn", "model", "model")
    assert_includes sealed_texts(child_run, "r1").join("\n"), "CAPTURED-ROLE-PROMPT"
    refute_includes sealed_texts(child_run, "r1").join("\n"), "UPDATED-ROLE-PROMPT"
    answer(child_pending)
    await_reply(child.public_id)
    await_run_status(parent, "completed")

    withdrawn, _turn, refused = rho_do(script([["spawn", { "role" => role, "prompt" => "!mock -- unavailable", "label" => "withdrawn" }]], "refused"))
    await_run_status(refused, "completed")
    assert_empty @conversations.conversation(withdrawn).children.items
    assert_includes task_result(refused, "r2t0"), "Choose one declaration by name"
    refute_includes task_result(refused, "r2t0"), role
    refute_includes sealed_texts(refused, "r1").join("\n"), "Use the original role configuration."

    publish(preset, role, "Use the updated role configuration.")
    fresh, _turn, next_run = rho_do(script([["spawn", { "role" => role, "prompt" => "!mock -- fresh child", "wait" => true, "label" => "fresh" }]], "received"))
    await_run_status(next_run, "completed")
    fresh_child = await_child(fresh, "fresh")
    fresh_run = await_reply(fresh_child.public_id).active_variant.run_public_id
    assert_equal MODEL, loop_row(fresh_run).dig("turn", "model", "model")
    assert_includes sealed_texts(fresh_run, "r1").join("\n"), "UPDATED-ROLE-PROMPT"
    refute_includes sealed_texts(fresh_run, "r1").join("\n"), "CAPTURED-ROLE-PROMPT"
    assert_equal identities, principal_ids
  end

  private

    def presets = @daemon.control(:get, "/presets").fetch("presets")

    def find_preset(preset) = presets.find { |row| row.fetch("public_id") == preset.fetch("public_id") }

    def principal_ids = @client.workspace(@room).principals.map(&:public_id).sort

    def create_preset(prefix, **configuration)
      name = "#{prefix}-#{SecureRandom.hex(3)}"
      answer = @daemon.control(:post, "/presets", body: { "name" => name, "description" => "Role E2E configuration",
        "configuration" => { "fallback_models" => [] }.merge(configuration.transform_keys(&:to_s)) })
      answer.fetch("presets").find { |row| row.fetch("name") == name }
    end

    def replace_preset(preset, **changes)
      current = find_preset(preset)
      @daemon.control(:put, "/presets", body: current.slice("public_id", "name", "description").merge(
        "configuration" => current.fetch("configuration").merge(changes.transform_keys(&:to_s))))
    end

    def publish(preset, name, description)
      @daemon.control(:put, "/presets/role", body: { "public_id" => preset.fetch("public_id"), "name" => name, "description" => description })
    end

    def script(calls, remainder, reply: nil)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      # Role capture needs the scripted calls intact, not an echo of the growing
      # tool directory that triggers the separate compaction journey.
      "!mock usage=100:5 reply=#{CGI.escape(reply || remainder)} tool_call=#{spelled.join(",")} -- #{remainder}"
    end

    def rho_do(prompt)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", @world.root)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def await_child(conversation, label)
      await("no child labelled #{label}") { @conversations.conversation(conversation).children.items.find { |row| row.parent&.label == label } }
    end

    def await_reply(conversation)
      await("no child reply settled") do
        turns = @conversations.conversation(conversation).turns.list.items.select { |turn| turn.role == "assistant" }
        failed = turns.find { |turn| turn.status == "failed" }
        flunk "child failed: #{failed.to_h.inspect}" if failed
        turns.find { |turn| turn.status == "completed" }
      end
    end

    def await_ask(run, prompt: nil)
      await("the expected question never arrived") do
        @daemon.control(:get, "/asks").fetch("asks").find do |row|
          row.fetch("kind") == "ask" && (run.nil? || row.fetch("run_public_id") == run) && (prompt.nil? || row.fetch("prompt") == prompt)
        end
      end
    end

    def answer(ask)
      @daemon.control(:post, "/answer", body: { "public_id" => ask.fetch("run_public_id"), "task_key" => ask.fetch("task_key"), "content" => "Continue." })
    end

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      assert_equal "200", response.code, response.body
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def loop_path(run) = "/agent_api/v1/workspaces/#{@room}/runs/#{run}"

    def loop_row(run) = agent_api(loop_path(run)).fetch("run")

    def task_result(run, key)
      task = agent_api("#{loop_path(run)}/tasks/#{key}").fetch("task")
      task["output"] || Array(task["content"]).filter_map { |block| block["text"] }.join
    end

    def sealed_texts(run, key)
      agent_api("#{loop_path(run)}/tasks/#{key}/request").fetch("request").fetch("entries").map do |entry|
        entry.fetch("parts", []).filter_map { |part| part["text"] }.join
      end
    end

    def await_run_status(run, status)
      await("run #{run} never reached #{status}") do
        row = loop_row(run)
        flunk "run failed: #{row["failure_reason"].inspect}" if row["status"] == "failed" && status != "failed"
        row if row["status"] == status
      end
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        value = yield
        return value if value
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(80).join
      warn "#{label}:\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
