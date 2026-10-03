require "test_helper"
require "cgi/escape"
require "cybros_control"
require "fileutils"
require "tempfile"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/mock_llm/app"
require "support/platform_http"
require "support/process_runner"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# The operator configures a catalog lane through cmctl's platform session;
# rho discovers and uses it through its own paired member identity. The fake
# provider rejects the keyed model unless that exact synthetic key reaches it.
class ModelManagementTest < Minitest::Test
  CMCTL_ROOT = File.expand_path("../../cmctl", __dir__)
  PROVIDER = "e2e-key".freeze
  MODEL = "e2e-key/mock-keyed-text".freeze

  def setup
    @base_url = E2E.base_url
    @people = E2E::ActorProvisioning.world(@base_url)
    @steward = @people.rho_steward
    @root = Dir.mktmpdir("model-management-e2e")
    @operator_home = File.join(@root, "operator")
    @rho_home = File.join(@root, "rho")
    @project = File.join(@root, "project")
    FileUtils.mkdir_p([@rho_home, @project])
    File.write(File.join(@rho_home, "settings.json"), JSON.generate("extensions" => []))
    E2E::SecretHygiene.register(E2E::MockLLM::App::API_KEY)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @rho_home, tools_root: @project, env: { "RHO_MODE" => "full" })
    @daemon.start
    actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho never adopted the steward's workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    E2E.hosts.start
  end

  def teardown
    unless passed?
      logs = [@daemon&.log_path, @daemon&.rho_log_path]
      logs << File.join(E2E.handle.fetch("log_dir"), "rails.log") if @base_url
      logs.compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path).lines.last(60).join) if File.file?(path)
      end
    end
    @daemon&.stop
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_an_operator_configures_a_lane_and_rho_discovers_and_uses_the_model
    login = cmctl("login", "--url", @base_url, "--email", @people.owner_email, "--password-stdin",
      stdin: "#{@people.owner_password}\n")
    assert login.fetch("connected")
    profile = cmctl("status")
    assert_nil profile.fetch("credential_plane"), "an API session is not an access token"
    assert_equal "human", profile.dig("member", "kind")
    credentials = CybrosControl::Config.new(home: @operator_home).read
    operator = CybrosAgent::PlatformClient.new(base_url: credentials.base_url, credential: credentials.token)
    assert_equal "USD", operator.cost_unit.fetch.cost_unit, "browser founding configures USD before any cost-unit command"
    assert_equal "USD", cmctl("account", "cost-unit", "USD").dig("account", "cost_unit")

    lane = cmctl("providers").fetch("model_providers").find { |row| row.fetch("id") == PROVIDER }
    refute lane.fetch("enabled")
    refute lane.fetch("configured")
    refute_includes rho_model_refs, MODEL

    installed = cmctl("provider", "key", "set", PROVIDER, "--stdin", stdin: "#{E2E::MockLLM::App::API_KEY}\n")
      .fetch("model_provider")
    assert installed.fetch("configured")
    assert installed.fetch("enabled"), "saving the key connects the provider"
    assert_includes rho_model_refs, MODEL

    disabled = cmctl("provider", "disable", PROVIDER).fetch("model_provider")
    refute disabled.fetch("enabled")
    assert disabled.fetch("configured"), "disabling the lane retains its saved key"
    refute_includes rho_model_refs, MODEL
    enabled = cmctl("provider", "enable", PROVIDER).fetch("model_provider")
    assert enabled.fetch("enabled")
    assert enabled.fetch("configured")

    discovered = rho_models("--workload", "text_generation").find { |row| row.fetch("ref") == MODEL }
    refute_nil discovered
    assert discovered.fetch("visible")
    assert discovered.fetch("available")
    assert discovered.dig("capabilities", "tool_calls")
    assert_includes cmctl("models", "--available", "--workload", "text_generation").fetch("models").map { |row| row.fetch("ref") }, MODEL
    assert_includes @daemon.control(:get, "/models?workload=text_generation").fetch("models").map { |row| row.fetch("ref") }, MODEL

    original = admin_model
    cmctl("model", "hide", MODEL)
    refute_includes rho_model_refs, MODEL
    hidden = admin_model
    refute hidden.fetch("visible")
    refute hidden.fetch("available")
    assert_equal "model_hidden", hidden.fetch("unavailable_reason")
    assert_equal original.except("visible", "available", "unavailable_reason"),
      hidden.except("visible", "available", "unavailable_reason"), "hiding preserves the model definition and pricing"

    output, status = @daemon.cli("run", "!mock reply=hidden -- say it", "--model", MODEL,
      "--dir", @project, "--output-format", "json", "--timeout", "60")
    assert_equal 1, status.exitstatus, E2E::SecretHygiene.redact(output)
    refused = JSON.parse(output)
    assert refused.fetch("is_error")
    assert_match(/model_hidden/, refused.fetch("reason"))

    cmctl("model", "unhide", MODEL)
    assert_equal original, admin_model
    assert_equal discovered, rho_models("--workload", "text_generation").find { |row| row.fetch("ref") == MODEL }

    output, status = @daemon.cli("run", "!mock reply=#{CGI.escape("configured through cmctl")} -- say it",
      "--model", discovered.fetch("ref"), "--dir", @project, "--output-format", "json", "--timeout", "60")
    assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    result = JSON.parse(output)
    assert_equal %w[result success completed], result.values_at("type", "subtype", "status")
    assert_equal "Mock: configured through cmctl", result.fetch("result").strip

    # A member bearer never acquires operator authority merely because the
    # same Human can discover models. The lane remains usable after refusal.
    denied = E2E::PlatformHttp.new(@base_url).put("/api/v1/admin/model_providers/#{PROVIDER}/lane",
      bearer: @steward.member_token, body: { command: { enabled: false, expected_lock_version: enabled.fetch("lock_version") } })
    assert_equal 401, denied.status
    assert_includes rho_model_refs, MODEL
    output, error, status = invoke_cmctl("login", "--url", @base_url, "--email", @steward.email, "--password-stdin",
      home: File.join(@root, "non-admin"), stdin: "#{@steward.password}\n")
    assert_equal 1, status.exitstatus
    assert_empty output
    assert_match(/owner or administrator/, error)

    refute cmctl("provider", "disable", PROVIDER).dig("model_provider", "enabled")
    refute_includes rho_model_refs, MODEL
    disabled = admin_model
    refute disabled.fetch("available")
    assert_equal "provider_disabled", disabled.fetch("unavailable_reason")
    cmctl("provider", "enable", PROVIDER)
    cleared = cmctl("provider", "key", "clear", PROVIDER).fetch("model_provider")
    assert cleared.fetch("enabled"), "removing a key does not change lane policy"
    refute cleared.fetch("configured")
    refute_includes rho_model_refs, MODEL
    unconfigured = admin_model
    refute unconfigured.fetch("available")
    assert_equal "missing_credential", unconfigured.fetch("unavailable_reason")
    cmctl("provider", "disable", PROVIDER)
    assert cmctl("logout").fetch("logged_out")
    _output, _error, status = invoke_cmctl("status")
    assert_equal 1, status.exitstatus
  end

  def test_a_custom_connection_and_unpriced_model_are_usable_without_a_restart
    cmctl("login", "--url", @base_url, "--email", @people.owner_email, "--password-stdin",
      stdin: "#{@people.owner_password}\n")
    provider = "e2e-custom-settings"
    model = "#{provider}/custom-chat"
    base_url = cmctl("provider", "show", PROVIDER).dig("configuration", "definition", "base_url")
    refute_nil base_url
    added = cmctl("provider", "add", provider, "--base-url", base_url,
      "--api-format", "openai_responses", "--credentials", "api_key", "--display-name", "Custom E2E provider")
    refute added.dig("model_provider", "enabled")
    assert_equal "custom", added.dig("configuration", "source")
    cmctl("provider", "key", "set", provider, "--stdin", stdin: "#{E2E::MockLLM::App::API_KEY}\n")
    directory = cmctl("provider", "discover", provider).fetch("models")
    assert_includes directory.map { |row| row.fetch("id") }, "mock-keyed-text"

    # The upstream directory supplies IDs, while an alias and its limits are
    # authored explicitly. No price is required for a usable model.
    cmctl("model", "add", model, "--model-id", "mock-keyed-text",
      "--input-tokens", "32768", "--output-tokens", "8192", "--tools")
    cmctl("provider", "enable", provider)
    row = rho_models("--workload", "text_generation").find { |item| item.fetch("ref") == model }
    refute_nil row
    assert row.fetch("available")
    assert_equal "unmetered", row.dig("pricing", "state")
    run_custom_model(model, "no price required", usage: "23:7")

    # An explicit zero schedule is a different fact from missing money, and a
    # later request observes the edit through the same running Nexus and rho.
    cmctl("model", "edit", model, "--input-price", "0", "--output-price", "0")
    row = rho_models("--workload", "text_generation").find { |item| item.fetch("ref") == model }
    assert_equal "known_free_candidate", row.dig("pricing", "state")
    run_custom_model(model, "explicit zero price", usage: "31:9")

    credentials = CybrosControl::Config.new(home: @operator_home).read
    now = Time.now.utc
    from = Time.utc(now.year, now.month, now.day)
    query = URI.encode_www_form(from: from.iso8601, to: (from + 86_400).iso8601, unit: "day",
      catalog_model_ref: model)
    report = E2E::PlatformHttp.new(@base_url).get("/api/v1/admin/model_usage/report?#{query}", bearer: credentials.token)
    assert_equal 200, report.status
    totals = report.body.fetch("report").fetch("totals")
    assert_equal 2, totals.fetch("request_count")
    assert_equal 54, totals.fetch("input_tokens")
    assert_equal 16, totals.fetch("output_tokens")
    refute totals.fetch("cost_complete"), "the first unpriced receipt must not become known zero"

    cmctl("model", "remove", model)
    refute_includes rho_model_refs, model
    removed = cmctl("provider", "reset", provider)
    assert_nil removed.dig("configuration", "definition")
    assert_equal "removed", removed.dig("configuration", "source")
    refute removed.dig("model_provider", "enabled")
    assert_equal removed, cmctl("provider", "show", provider)
    restored = cmctl("provider", "add", provider, "--base-url", base_url,
      "--api-format", "openai_responses", "--credentials", "api_key")
    refute restored.dig("model_provider", "enabled")
    assert_equal "custom", restored.dig("configuration", "source")
    cmctl("provider", "key", "clear", provider)
    cmctl("provider", "reset", provider)
    cmctl("logout")
  end

  private

    def run_custom_model(model, reply, usage:)
      output, status = @daemon.cli("run", "!mock reply=#{CGI.escape(reply)} usage=#{usage} -- say it",
        "--model", model, "--dir", @project, "--output-format", "json", "--timeout", "60")
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      result = JSON.parse(output)
      assert_equal %w[result success completed], result.values_at("type", "subtype", "status")
      assert_equal "Mock: #{reply}", result.fetch("result").strip
    end

    def rho_model_refs
      rho_models("--workload", "text_generation").map { |row| row.fetch("ref") }
    end

    def admin_model
      cmctl("models", "--workload", "text_generation").fetch("models").find { |row| row.fetch("ref") == MODEL }
    end

    def rho_models(*options)
      output, status = @daemon.cli("models", "--json", *options)
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      JSON.parse(output).fetch("models")
    end

    def cmctl(*arguments, **options)
      output, error, status = invoke_cmctl(*arguments, **options)
      assert_predicate status, :success?, E2E::SecretHygiene.redact("cmctl #{arguments.join(" ")}: #{error}\n#{output}")
      assert_empty error
      refute_includes output, E2E::MockLLM::App::API_KEY
      JSON.parse(output)
    end

    def invoke_cmctl(*arguments, home: @operator_home, stdin: nil)
      env = {
        "BUNDLE_GEMFILE" => File.join(CMCTL_ROOT, "Gemfile"),
        "BUNDLE_LOCKFILE" => File.join(CMCTL_ROOT, "Gemfile.lock"),
        "BUNDLE_FROZEN" => "true", "RUBYOPT" => nil, "RUBYLIB" => nil,
      }
      Tempfile.create("cmctl-stdout") do |output|
        Tempfile.create("cmctl-stderr") do |error|
          status = E2E::ProcessRunner.run(Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "cmctl", "--home", home,
            *arguments, env: env, chdir: CMCTL_ROOT, stdin: stdin, out: output, err: error, timeout: 45)
          [output.tap(&:rewind).read, error.tap(&:rewind).read, status]
        end
      end
    end
end
