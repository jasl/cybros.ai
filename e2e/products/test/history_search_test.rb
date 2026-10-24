require "test_helper"
require "cgi/escape"
require "fileutils"
require "securerandom"
require "shellwords"
require "tempfile"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/process_runner"
require "support/rho_daemon"
require "support/steward_session"
require_relative "history_search/retention_fixture"

# Public history reads use the same live timeline as a conversation. The only
# out-of-band fixture advances one completed execution's age, then invokes the
# production cleanup job in the isolated E2E database.
class HistorySearchTest < Minitest::Test
  CMCTL_ROOT = File.expand_path("../../../cmctl", __dir__)
  MODEL = "dev/mock-text".freeze

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    @steward = @people.rho_steward
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @client.workspaces.create(name: "History #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid).workspace
    @room = @client.workspace(@workspace.public_id)
    @home = Dir.mktmpdir("rho-history-e2e")
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    @daemon&.stop
    if @workspace
      current = @client.workspaces.fetch(@workspace.public_id)
      @room.delete(lock_version: current.lock_version)
    end
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_rho_recalls_retained_text_after_configurable_execution_cleanup
    boot_rho
    text = "The telescope remembers中文安装 steps."
    output, status = @daemon.cli("do", "!mock reply=#{CGI.escape(text)} -- remember", "--model", MODEL, "--dir", @project)
    assert_predicate status, :success?, output
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil conversation_id, output
    refute_nil loop_id, output
    chat = @rho_room.conversation(conversation_id)
    original = settled_reply(chat)
    original_text = original.text

    cmctl("login", "--url", @base_url, "--email", @people.owner_email,
      "--password-stdin", stdin: "#{@people.owner_password}\n")
    previous = cmctl("account", "retention").dig("account", "execution_details_retention_days")
    begin
      assert_nil cmctl("account", "retention", "off").dig("account", "execution_details_retention_days")
      fixture = E2E::HistoryRetentionFixture.new
      fixture.age(loop_id)
      fixture.prune
      assert_nil chat.turns.list.items.last.active_variant.details_pruned_at
      assert_equal 1, cmctl("account", "retention", "1").dig("account", "execution_details_retention_days")
      fixture.prune
      retained = chat.turns.list.items.last
      refute_nil retained.active_variant.details_pruned_at
      assert_equal original_text, retained.text
      assert_equal "unavailable", retained.active_variant.runner_effects.status
      assert_equal "execution_details_pruned", retained.active_variant.runner_effects.reason
      assert_equal original_text, chat.history.list.turns.last.content
      assert_equal original_text, chat.turns.field(retained.public_id, retained.active_variant.public_id, "content").text
      assert_includes @rho_room.conversations.search(query: "telescope 安装").matches.map(&:conversation_public_id), conversation_id

      results = recall_tools(chat, [
        ["session_search", { query: "telescope 安装" }],
        ["session_read", { session_id: conversation_id, around_turn_id: original.public_id, limit: 1 }],
      ])
      search = results.fetch("session_search")
      assert_includes search.fetch("matches").map { |hit| hit.fetch("conversation_public_id") }, conversation_id
      read = results.fetch("session_read")
      assert_equal original_text, read.fetch("turns").first.fetch("content")
    ensure
      cmctl("account", "retention", previous ? previous.to_s : "off")
    end
  end

  private

    def settled_reply(chat, after: -1)
      await("conversation reply did not complete") do
        turn = chat.turns.list.items.find { |item| item.position > after && item.kind == "direct_reply" }
        flunk turn.to_h.inspect if turn&.status == "failed"
        turn if turn&.status == "completed"
      end
    end

    def boot_rho
      @project = File.join(@home, "project")
      FileUtils.mkdir_p(@project)
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: File.join(@home, "rho"), tools_root: @project)
      @daemon.start
      actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      status = @daemon.await("rho did not adopt its workspace") do
        value = @daemon.status
        value if value.dig("workspace", "state") == "adopted"
      end
      @rho_room = @client.workspace(status.dig("workspace", "public_id"))
    end

    def recall_tools(chat, calls, answered: 0)
      after = chat.turns.list.items.map(&:position).max || -1
      # The stateless mock's clock counts tool answers retained in earlier turns.
      script = Array.new(answered, calls.first) + calls
      @daemon.control(:post, "/say", body: { "public_id" => chat.public_id,
        "text" => mock_calls(script),
        "delivery_mode" => "queue" })
      turn = settled_reply(chat, after: after)
      loop = @rho_room.runs.run(turn.active_variant.run_public_id)
      tasks = loop.fetch.tasks
      calls.to_h do |name, _arguments|
        task = tasks.find { |item| item.tool_name == name }
        refute_nil task, "#{name} was not called: #{tasks.map { |item| [item.key, item.tool_name, item.status] }.inspect}; #{turn.text}"
        [name, JSON.parse(loop.task(task.key).output)]
      end
    end

    def mock_calls(calls, reply: "Read complete", message: "recall")
      script = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }.join(",")
      "!mock reply=#{CGI.escape(reply)} tool_call=#{script} -- #{message}"
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
      loop do
        result = yield
        return result if result
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
      end
    end

    def cmctl(*arguments, stdin: nil)
      env = { "BUNDLE_GEMFILE" => File.join(CMCTL_ROOT, "Gemfile"),
        "BUNDLE_LOCKFILE" => File.join(CMCTL_ROOT, "Gemfile.lock"), "BUNDLE_FROZEN" => "true",
        "RUBYOPT" => nil, "RUBYLIB" => nil }
      Tempfile.create("history-cmctl-output") do |output|
        Tempfile.create("history-cmctl-error") do |error|
          status = E2E::ProcessRunner.run(Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "cmctl",
            "--home", File.join(@home, "operator"), *arguments, env: env, chdir: CMCTL_ROOT,
            stdin: stdin, out: output, err: error, timeout: 45)
          result = output.tap(&:rewind).read
          diagnostics = error.tap(&:rewind).read
          assert_predicate status, :success?, "#{diagnostics}\n#{result}"
          JSON.parse(result)
        end
      end
    end
end
