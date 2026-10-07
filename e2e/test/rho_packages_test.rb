require "test_helper"
require "cgi/escape"
require "fileutils"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

class RhoPackagesTest < Minitest::Test
  def setup
    @base_url = E2E.base_url
    steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
    @root = Dir.mktmpdir("rho-packages-e2e")
    @home = File.join(@root, "home")
    @project = File.join(@root, "work")
    FileUtils.mkdir_p([@home, @project])
    File.write(File.join(@home, "settings.json"), JSON.generate({ "settings_version" => 1, "plugins" => {}, "api_only" => true }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project)
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("the personal agent never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "agent")
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: steward.member_token)
    @workspace = @member.workspace(@daemon.status.dig("workspace", "public_id"))
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path)) if File.file?(path)
      end
    end
    @daemon&.dispose_connection
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_a_personal_package_is_checked_announced_called_replaced_and_restored_after_restart
    candidate = File.join(@project, "greeting")
    FileUtils.cp_r(File.expand_path("../fixtures/personal_extension", __dir__), candidate)
    config = File.join(@project, "configuration.json")
    File.write(config, JSON.generate({ "person" => "Ada" }))

    first = cli_json("extensions", "install", candidate)
    assert_managed_package_check(first.fetch("version"))
    cli_json("extensions", "activate", "personal-greeting", first.fetch("version"), "--configuration", config)
    assert_tool_result(first.fetch("version"), "Hello, Ada.")

    source = File.join(candidate, "extension.rb")
    File.write(source, File.read(source).sub('WORD = "Hello"', 'WORD = "Welcome"'))
    second = cli_json("extensions", "install", candidate)
    refute_equal first.fetch("version"), second.fetch("version")
    cli_json("extensions", "activate", "personal-greeting", second.fetch("version"))
    assert_tool_result(second.fetch("version"), "Welcome, Ada.")

    @daemon.stop
    @daemon.start
    @daemon.await_announced(address: "agent")
    selected = cli_json("extensions", "packages").fetch("packages").find { |row| row.fetch("active") }
    assert_equal second.fetch("version"), selected.fetch("version")
    configuration = cli_json("extensions", "list").fetch("plugins").find { |row| row.fetch("id") == "personal-greeting" }
    assert_equal({ "person" => "Ada" }, configuration.dig("configuration", "overrides"))
    assert_tool_result(second.fetch("version"), "Welcome, Ada.")
    cli_json("extensions", "rollback", "personal-greeting")
    assert_tool_result(first.fetch("version"), "Hello, Ada.")
  end

  private

    def cli_json(*arguments)
      output, status = @daemon.cli(*arguments)
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      JSON.parse(output)
    end

    def assert_managed_package_check(version)
      arguments = { "action" => "check", "name" => "personal-greeting", "version" => version }
      prompt = "!mock tool_call=manage_extension tool_args=#{CGI.escape(JSON.generate(arguments))} -- Check my installed personal extension."
      answer = cli_json("run", prompt, "--model", "dev/mock-text", "--dir", @project, "--output-format", "json")
      assert_equal "completed", answer.fetch("status"), answer.inspect
      run = @workspace.runs.run(answer.fetch("run_id"))
      task = run.fetch.tasks.find { |row| row.tool_name == "manage_extension" }
      refute_nil task, "the model must invoke the managed owner through Nexus"
      assert_equal "completed", task.status
      refute task.result["is_error"], task.to_h.inspect
      refute_nil task.approval, "the ordinary approval stage judges the managed operation"
      assert JSON.parse(run.task(task.key).output).fetch("passed"), "the managed owner executes the package checks"
    end

    def assert_tool_result(version, expected)
      name = "personal_greeting_#{version[0, 12]}"
      prompt = "!mock tool_call=#{name} tool_args=#{CGI.escape("{}")} -- use my greeting"
      answer = cli_json("run", prompt, "--model", "dev/mock-text", "--dir", @project, "--output-format", "json")
      assert_equal "completed", answer.fetch("status"), answer.inspect
      result = @daemon.control(:get, "/runs/transcript?public_id=#{answer.fetch("run_id")}")
      assert_includes JSON.generate(result), expected
    end
end
