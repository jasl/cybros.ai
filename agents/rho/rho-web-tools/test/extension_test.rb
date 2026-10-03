require "test_helper"
require "open3"
require "rbconfig"

# THE DOOR IT COMES THROUGH is the door the built-ins use: `register(api)`
# on the runner's `Api` — one tool, one command, no failure — the
# loader's failure record on a bad `web` table (the two sentences),
# `Loader.available` seeing the gem's metadata key, the defaults without
# a host, and the config once.
class ExtensionTest < Minitest::Test
  include WebToolsTest::Helpers

  Host = Struct.new(:config, keyword_init: true)
  Config = Struct.new(:web, keyword_init: true)

  # rho's daemon hands a subclass with `register_command`; this one keeps
  # what it was given, so the verb's registration is a fact to read.
  class HostApi < Rho::Runner::Extensions::Api
    attr_reader :commands

    def initialize(**)
      super
      @commands = []
    end

    def register_command(name, **options, &handler)
      @commands << [name, options, handler]
      self
    end
  end

  def teardown
    halt_servers
    Rho::WebTools.reset!
  end

  def load(web: nil, host: true)
    options = host ? { host: Host.new(config: Config.new(web: web)) } : {}
    Rho::Runner::Extensions::Loader.call(builtin: [Rho::WebTools], api_class: HostApi, api_options: options)
  end

  def test_it_registers_one_tool_and_one_verb_through_the_public_loader
    result = load(web: { "allow_private_network" => true })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal ["web_fetch"], result.registry.names
    assert_equal ["rho.web_tools"], result.registry.extension_names
    assert_equal({ "kind" => "read_only", "destructive" => false, "world" => "open",
                   "idempotency" => "intrinsic", "reconciliation" => "none" }, result.registry.effect_profile("web_fetch"))
    api = result.committed.fetch(0)
    assert_equal 1, api.commands.length
    name, options, handler = api.commands.fetch(0)
    assert_equal "web", name
    assert_equal "web fetch URL [--raw]", options.fetch(:usage)
    assert_equal({ raw: { type: :boolean, default: false, desc: "Print the rendering's bytes as they are, unescaped" } },
      options.fetch(:options))
    assert_kind_of Proc, handler
    assert_empty api.lifecycle, "no shutdown hook: the tool holds nothing"
    assert Rho::WebTools.allow_private_network?
    assert_equal({ "allow_private_network" => true }, Rho::WebTools.settings)
    assert_predicate Rho::WebTools.settings, :frozen?
  end

  def test_the_announcement_carries_the_declaration_byte_for_byte
    entry = load.registry.serving(:runner).announcement.fetch(0)
    assert_equal "web_fetch", entry.fetch("name")
    assert_equal Rho::WebTools::Tools::Fetch::DESCRIPTION, entry.fetch("description")
    assert_equal Rho::WebTools::Tools::Fetch::SCHEMA, entry.fetch("input_schema")
    assert_equal 60_000, entry.fetch("timeout_ms")
    assert_equal "open", entry.dig("effect_profile", "world")
  end

  def test_reregistering_settings_changes_the_next_call_on_an_existing_tool_instance
    app = WebToolsTest::FixtureApp.new
    site = serve(app)
    loaded = load(web: { "allow_private_network" => false })
    assert_predicate loaded, :ok?, loaded.failures.inspect

    with_tool_env do |env, _root|
      # The handler retains the instance built by the original registry.
      handler = loaded.registry.toolset(env: env).fetch("web_fetch").handler
      arguments = { "url" => "#{site}/page.html" }
      denied = handler.call(arguments, nil)
      assert_predicate denied, :is_error
      assert_equal Rho::WebTools::Client.new.private_sentence("127.0.0.1"), denied.content
      assert_empty app.seen

      changed = load(web: { "allow_private_network" => true })
      assert_predicate changed, :ok?, changed.failures.inspect
      allowed = handler.call(arguments, nil)
      refute_predicate allowed, :is_error
      assert_equal 200, allowed.structured_content.fetch("status")
      assert_includes allowed.content, "# Fixture Heading"
      assert_equal 1, app.seen.length

      changed = load(web: { "allow_private_network" => false })
      assert_predicate changed, :ok?, changed.failures.inspect
      denied_again = handler.call(arguments, nil)
      assert_predicate denied_again, :is_error
      assert_equal denied.content, denied_again.content
      assert_equal 1, app.seen.length, "the next call is blocked before reaching the fixture"
    end
  end

  def test_a_bad_web_table_is_this_extensions_failure_with_its_sentence
    result = load(web: { "allow_private_network" => "yes" })
    refute_predicate result, :ok?
    assert_empty result.registry.names
    failure = result.failures.fetch(0)
    assert_equal "Rho::Runner::Extensions::RegistrationError", failure.error_class
    assert_equal "settings.json \"web\": allow_private_network must be true or false, not \"yes\"", failure.message

    result = load(web: { "allow_private_networks" => true })
    assert_equal "settings.json \"web\": unknown key \"allow_private_networks\"; the keys are allow_private_network",
      result.failures.fetch(0).message
  end

  def test_a_standalone_runner_takes_the_default_and_a_host_with_an_empty_table_too
    result = load(host: false)
    assert_predicate result, :ok?, result.failures.inspect
    refute Rho::WebTools.allow_private_network?
    result = load(web: {})
    assert_predicate result, :ok?
    refute Rho::WebTools.allow_private_network?
  end

  def test_the_gem_declares_the_loaders_metadata_key
    spec = Gem::Specification.load(File.expand_path("../rho-web-tools.gemspec", __dir__))
    assert_equal "rho/web-tools", spec.metadata["rho_extensions"]
    assert_equal %w[reverse_markdown rho-runner], spec.runtime_dependencies.map(&:name).sort
    assert_equal "Rho::WebTools", Rho::Runner::Extensions::Loader.send(:module_named, "rho/web-tools").name
  end

  def test_the_markdown_config_is_written_once_and_is_idempotent
    load
    assert_equal :bypass, ReverseMarkdown.config.unknown_tags
    assert ReverseMarkdown.config.github_flavored
    load
    assert_equal :bypass, ReverseMarkdown.config.unknown_tags
  end

  # THE LOAD IS SILENT UNDER `ruby -w` (the removal series' leftover):
  # httpx's SSRF filter computes its IPv6 blacklist at plugin load through
  # `IPAddr#ipv4_compat`, which `warn`s "obsolete" under `$VERBOSE`
  # (ipaddr.rb, guarded by `if $VERBOSE`, no category) — sixteen lines on
  # stderr at the FIRST session of a process, inside whichever test
  # captured stderr first (`CommandsTest` anchors the status line to the
  # whole of stderr). A subprocess, because a plugin's module body runs
  # once per process: the property is "requiring rho/web-tools and building the
  # filtered session prints nothing", and only a fresh process shows it.
  def test_requiring_the_gem_under_warnings_prints_no_third_party_warning
    script = 'require "rho/web-tools"; Rho::WebTools::Client.new.send(:build_session, URI("https://example.com/")); ' \
             "$stdout.print(HTTPX::Plugins.load_plugin(:ssrf_filter).name)"
    out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", File.expand_path("../lib", __dir__), "-e", script)
    assert_predicate status, :success?, err
    assert_equal "HTTPX::Plugins::SsrfFilter", out
    assert_equal "", err, "a warning under -w: #{err}"
  end

  def test_the_guideline_reaches_the_prompt_fragments
    fragments = load.registry.prompt_fragments
    assert_equal ["Fetch a web page by URL"], fragments.map { |f| f["snippet"] }.compact
    assert_equal Rho::WebTools::Tools::Fetch::PROMPT_GUIDELINES, fragments.flat_map { |f| f["guidelines"] }
  end
end
