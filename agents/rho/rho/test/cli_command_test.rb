require "test_helper"
require "socket"
require "tmpdir"

# The dispatcher, driven as a person drives it: a real subprocess, real argv,
# real exit status. `core_test.rb` drives `Rho::Core`, `cli/terminal_test.rb`
# the terminal, and `test/daemon` the
# daemon, both as libraries, which is exactly how a CLI edit can pass every gate
# while the shipped binary prints something else — this round has already been
# bitten by that once. Since the reshape the binary also LOADS the extensions
# and installs their verbs before Thor parses, so what it lists, what it parses
# and what it says when a load fails are pinned here and nowhere else.
class CliCommandTest < Minitest::Test
  include RhoTest::CliHarness

  EXE = File.expand_path("../exe/rho", __dir__)
  ROOT = File.expand_path("..", __dir__)
  # THE CORE IS THE CONTROL PLANE: the
  # ceremony, the daemon, the install verbs, and `run` — the one
  # conversation verb a product install carries. Everything else that
  # operates a conversation (`do`, `say`, `stop`, `watch`, the Ops verbs)
  # is rho-dev's, a development gem a home names; a PRODUCT home — this
  # test's, which names nothing — lists none of it. `compact` is rho-dev's
  # too: the exception rule — a repair verb a runner-mode rho needs stays
  # core — names nothing today.
  CORE_VERBS = %w[connect disconnect status server version run extensions settings].freeze
  EXTENSION_VERBS = {
    "rho.processes" => %w[processes kill logs],
    "rho.environment" => %w[env runner],
    "rho.console_link" => %w[console],
    "rho.default_runner" => %w[runners set_default_runner],
    "rho.ops" => %w[models workspaces],
    "rho.setup" => %w[setup],
  }.freeze
  # rho-dev's verbs, none of which a product home lists (the dev-home
  # listing is rho-dev's own `dev_cli_test`).
  DEV_VERBS = %w[do say stop watch runs result follow transcript task attach retry abandon compact delete
                 adaptations request prompt fetch].freeze

  # Its own bundle and its own RHO_HOME: a CLI test that wrote into the
  # developer's real home, or resolved against the harness's lockfile, would be
  # testing something other than what ships.
  def run_rho(*argv, env: {})
    out = IO.popen(
      { "RHO_HOME" => @root, "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") }.merge(env),
      [Gem.ruby, EXE, *argv], err: [:child, :out]
    ) { |io| io.read }
    # UTF-8 BY NAME. This machine has no LANG, so the test process's
    # `default_external` is US-ASCII and the binary's own em dashes come back
    # as an invalid string that every regex raises on. `exe/rho` fixes its own
    # output encoding; the reader has to say so too.
    [out.to_s.force_encoding(Encoding::UTF_8).scrub, $?.exitstatus]
  end

  # An extension file the binary will load from this home's settings.
  def install_extension(body, id:, file: "ext.rb")
    path = File.join(@root, file)
    File.write(path, body)
    home.prepare
    Rho::StateFile.new(home.settings_path).write("plugins" => { id => RhoTest.described_extension(path, id: id) })
    path
  end

  # `Thor::Actions` defines `run`, which is the one conversation verb's
  # name: it is never included, so `rho run` is rho's.
  def test_the_dispatcher_never_includes_thor_actions
    # `Rho::Command` lives in the binary, whose last line dispatches: the
    # class is read in a subprocess with that line cut, and asked.
    probe = 'source = File.read(ARGV.first, encoding: "UTF-8").sub(/^Rho::Command\.start\(ARGV\)\s*\z/, ""); ' \
            "eval(source, binding, ARGV.first); print Rho::Command.include?(Thor::Actions)"
    out = IO.popen({ "RHO_HOME" => @root, "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile") },
      [Gem.ruby, "-e", probe, EXE], err: [:child, :out]) { |io| io.read }
    assert_equal "false", out.to_s.strip, "Thor::Actions defines `run`; the verb is rho's"
  end

  def test_version_prints_the_version_and_succeeds
    out, status = run_rho("version")

    assert_equal 0, status
    assert_equal Rho::VERSION, out.strip
  end

  # The help text is where a person learns the verb set, so it is asserted
  # against the verbs rather than against a snapshot: the seven core verbs
  # first, then every extension's under its own heading.
  def test_help_lists_every_verb_by_owner_and_keeps_the_doctrine
    out, status = run_rho("help")

    assert_equal 0, status
    core, *extensions = out.split(/^Extension /)
    # A mapped verb is only real if Thor actually routed it: `do` and `say`
    # are spelled one way and dispatched another.
    CORE_VERBS.each { |verb| assert_match(/^\s+rho #{verb}\b/, core, "`rho help` must list #{verb} as core") }
    DEV_VERBS.each { |verb| refute_match(/^\s+rho #{verb}\b/, out, "`#{verb}` is rho-dev's; a product home lists it nowhere") }
    refute_match(/^Extension rho\.dev:/, out, "rho-dev is not named here")
    EXTENSION_VERBS.each do |extension, verbs|
      section = extensions.find { |candidate| candidate.start_with?("#{extension}:") }
      refute_nil section, "`rho help` must head a section for #{extension}"
      verbs.each { |verb| assert_match(/^\s+rho #{verb}\b/, section, "#{verb} must be listed under #{extension}") }
      refute_match(/^\s+rho procs\b/, section, "an alias is not listed")
    end
    assert_match(/--url. is reserved/, out, "why the flag is --nexus-url is doctrine, not decoration")
    assert_match(/One RHO_HOME is one Nexus/, out)
    assert_match(/RHO_WORK_DIR/, out)
    assert_match(/code-owned registration identity/, out)
    assert_match(/never\s+copy RHO_HOME or credentials/, out)
    assert_match(/rho set_default_runner HOST_ID EXECUTOR_ID/, out)
    assert_match(/Accepted tasks keep their original target/, out)
    refute_match(/rho tree/, out, "the framework's generated verb is not rho's")
  end

  def test_connect_help_keeps_registration_identity_and_runner_policy_out_of_the_cli
    out, status = run_rho("help", "connect")

    assert_equal 0, status
    refute_match(/--agent-identifier/, out)
    refute_match(/--runner-identifier/, out)
    refute_match(/--runner\b/, out)
    refute_match(/--assignment-scope/, out)
    refute_match(/--mode/, out, "the mode is a boot fact: `rho server --mode`, never connect's")
    refute_match(
      /--display-name/, out,
      "the live daemon, not a later connect client, owns its registration display"
    )

    server, server_status = run_rho("help", "server")
    assert_equal 0, server_status
    assert_match(/--display-name/, server)
    assert_match(/--mode=MODE/, server)
    assert_match(/full \(agent \+ runner on one machine, the default\)/, server)
    assert_match(/--workspace=WORKSPACE/, server, "the room knob is a boot fact beside the mode")
    assert_match(/Override the default workspace for this boot/, server)

    run_help, run_status = run_rho("help", "run")
    assert_equal 0, run_status
    assert_match(/--runner=RUNNER/, run_help)
    assert_match(/--agent=AGENT/, run_help, "a human names the answerer")
    refute_match(/--approval|--stream|--restricted/, run_help, "rho-dev's `do` knobs are not `run`'s")

    disconnect, disconnect_status = run_rho("help", "disconnect")
    assert_equal 0, disconnect_status
    assert_match(/Revoke this machine's credentials on Nexus and forget them/, disconnect)
    assert_match(/--runner/, disconnect)
  end

  # In runner mode the conversation verbs are not here, and the footer says so.
  def test_in_runner_mode_help_lists_no_conversation_verb_and_says_so
    home.prepare
    Rho::StateFile.new(home.settings_path).write("mode" => "runner")
    out, status = run_rho("help")

    assert_equal 0, status
    %w[run do say stop compact watch models].each { |verb| refute_match(/^\s+rho #{verb}\b/, out, "#{verb} is not a runner's verb") }
    %w[connect disconnect status server env runner processes].each do |verb|
      assert_match(/^\s+rho #{verb}\b/, out, "#{verb} stands")
    end
    assert_match(/This rho is in mode runner: it serves tools and opens no conversations/, out)
    assert_match(/\(`run` is not here\)/, out)
  end

  # An extension verb's options reach Thor: `help VERB` shows them, and the
  # class option every verb takes. (`VERB --help` is not a help request to
  # this Thor — it reads `--help` as the first argument.)
  def test_an_extension_verbs_help_shows_its_own_option_and_the_shared_one
    out, status = run_rho("help", "env")

    assert_equal 0, status
    assert_match(/rho env \[DIR\]/, out)
    assert_match(/--clear/, out)
    assert_match(/--nexus-url/, out)

    # An option is never a word of the usage line (Thor counts the line's
    # words as the verb's arity): `--tail` reaches `help` as an option and
    # `rho logs ID` is one word.
    logs, status = run_rho("help", "logs")
    assert_equal 0, status
    assert_match(/rho logs ID$/, logs)
    assert_match(/--tail/, logs)
  end

  def test_models_help_offers_workload_and_json_for_the_available_listing
    out, status = run_rho("help", "models")

    assert_equal 0, status
    assert_match(/--workload/, out)
    assert_match(/--json/, out)
    refute_match(/--available/, out)
  end

  def test_workspace_subcommands_reach_the_daemon_and_persist_only_a_confirmed_selection
    workspace = { "public_id" => "ws-2", "name" => "Shared lab" }
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /workspaces " => [[200, { "workspaces" => [workspace], "workspace" => workspace }]],
      "POST /workspaces " => [[201, { "workspace" => workspace }]],
      "POST /workspaces/select " => [[200, { "workspace" => workspace }]],
      "PATCH /settings " => [[200, { "settings" => { "workspace" => "ws-2" } }]]
    ))

    [[], ["list"]].each do |words|
      output, status = run_rho("workspaces", *words, "--json")
      assert_equal 0, status, output
      assert_equal [workspace], JSON.parse(output).fetch("workspaces")
    end

    created, status = run_rho("workspaces", "create", "Shared lab", "--json")
    assert_equal 0, status, created
    assert_equal workspace, JSON.parse(created)
    assert_nil home.settings_workspace, "creation alone does not change the selected default"

    selected, status = run_rho("workspaces", "use", "ws-2", "--json")
    assert_equal 0, status, selected
    assert_equal workspace, JSON.parse(selected)
    saved_request = seen.find { |request| request.start_with?("PATCH /settings ") }
    assert_equal({ "workspace" => "ws-2" }, JSON.parse(saved_request.split("\r\n\r\n", 2).last))
    created_request = seen.find { |request| request.start_with?("POST /workspaces ") }
    body = JSON.parse(created_request.split("\r\n\r\n", 2).last)
    assert_equal "Shared lab", body.fetch("name")
    refute_empty body.fetch("idempotency_key")
    selected_request = seen.find { |request| request.start_with?("POST /workspaces/select ") }
    assert_equal({ "public_id" => "ws-2" }, JSON.parse(selected_request.split("\r\n\r\n", 2).last))
  end

  # Too few or too many words is Thor's own usage error for an extension
  # verb, exactly as for a core one, and an alias reaches the verb.
  def test_an_extension_verb_counts_its_words_and_answers_to_its_alias
    out, status = run_rho("kill")
    assert_equal 1, status
    assert_match(/"rho kill" was called with no arguments/, out)
    assert_match(/Usage: "rho kill ID"/, out)

    out, status = run_rho("env", "a", "b")
    assert_equal 1, status
    assert_match(/was called with arguments \["a", "b"\]/, out)

    out, status = run_rho("procs")
    assert_equal 1, status
    assert_match(/\Arho processes: no local daemon is running/, out, "the alias dispatched to the verb")

    # `logs ID` with `--tail` declared as an OPTION: one word reaches the
    # verb, plain or flagged (the usage-line law below).
    out, status = run_rho("logs", "p1", "--tail", "5")
    assert_equal 1, status
    assert_match(/\Arho logs: no local daemon is running/, out, "the flag is an option, never a usage word")
  end

  # THE USAGE-LINE LAW, guarded over EVERY verb: Thor counts a usage line's
  # words as the verb's arity (exe/rho's Arity), so a usage names POSITIONALS
  # only — uppercase placeholders, bracketed when optional, lowercase
  # sub-verbs — never an option. The rule broke four times on record
  # (`rho request`, `conversation participants`, `transcript [--prefix KEY]`,
  # `fetch [--thumbnail | --preview]`); this pin makes the fifth impossible.
  # EVERY line: Thor cuts the listing to the terminal's width and a line
  # it cut carries `...` where the `#` would be — the fifth break
  # (`approve RUN_ID TASK_KEY [--always] [--match PREFIX]`) hid behind that cut on 32 of 53 lines — so the help is read at
  # a width nothing is cut at, and a line the scan missed is a failure.
  # This is the PRODUCT home's listing; rho-dev's `dev_cli_test` runs the
  # same law over a home that names the development gem.
  def test_every_usage_line_names_positionals_only
    help, status = run_rho("help", env: { "THOR_COLUMNS" => "400" })
    assert_equal 0, status
    listed = help.lines.count { |line| line.match?(/^\s+rho \S/) }
    usages = help.scan(/^\s*rho (\S.*?)\s{2,}#/).flatten
    refute_empty usages, "help lists the verbs with their usage lines"
    assert_equal listed, usages.length, "every listed verb's usage line is scanned; Thor cut one:\n#{help}"
    offenders = usages.flat_map do |usage|
      usage.split("|").flat_map do |alternative|
        alternative.split.drop(1).reject { |word| word.match?(/\A\[?(?:[A-Z][A-Z0-9_]*|[a-z][a-z_-]*)(?:\.\.\.)?\]?\z/) }
                   .map { |word| "#{usage.strip}: #{word.inspect}" }
      end
    end
    assert_empty offenders, "an option is never a word of a usage line"
  end

  # A PRODUCT HOME HAS NO SECOND MESSAGE: `do`, `say`, `stop` and the Ops
  # verbs are rho-dev's, and typing one here is an unknown verb, refused
  # the way any mistyped verb is — never a quiet success, never a hint
  # naming a gem the product does not carry.
  def test_the_conversation_verbs_are_unknown_on_a_product_home
    %w[do say stop watch].each do |verb|
      out, status = run_rho(verb, "c-9", "--nexus-url", "https://nexus.example")
      assert_equal 1, status, "`rho #{verb}` must not read as success on a product home:\n#{out}"
      assert_match(/Could not find command "#{verb}"/, out, out)
    end
  end

  def test_an_unknown_command_fails_rather_than_succeeding_quietly
    out, status = run_rho("bogus")

    assert_equal 1, status, "a mistyped verb must not read as success to a supervisor"
    assert_match(/bogus/, out)
  end

  # A verb nobody answers names the extension that might have; a verb
  # somebody answers never mentions a failure at all.
  def test_an_unknown_verb_after_an_extension_failed_to_load_says_so
    path = install_extension(<<~RUBY, id: "rho.deploy")
      module DeployExtension
        NAME = "rho.deploy"
        def self.register(api)
          raise ArgumentError, "no deploy target configured"
        end
      end
    RUBY

    out, status = run_rho("deploy", "prod")
    assert_equal 1, status
    assert_match(/\Arho deploy: no such verb; extension #{Regexp.escape(path)} did not load \(ArgumentError\): no deploy target configured/, out)

    out, status = run_rho("env", "--nexus-url", "https://nexus.example")
    assert_equal 1, status
    assert_equal "rho env: no local daemon is running; start one with `rho server`\n", out,
      "another extension's verb is not the place to report the failure"
  end

  # A CORE VERB NEVER CARRIES A LOAD FAILURE: the journeys regex `rho
  # status`'s lines with stderr merged in, and a settings file naming a
  # broken extension must not prepend a line to them.
  def test_a_broken_extension_file_leaves_the_status_lines_exactly_as_they_are
    install_extension("module Broken; NAME = 'rho.broken'; def self.register(_api) = raise('boom'); end", id: "rho.broken")

    out, status = run_rho("status", "--nexus-url", "https://nexus.example")

    assert_equal 0, status
    instance = JSON.parse(File.read(File.join(@root, "instance.json"), encoding: Encoding::UTF_8)).fetch("id")
    assert_equal ["nexus:     https://nexus.example", "mode:      full", "instance:  #{instance}",
                  "daemon:    not running", "state:     not connected", "adaptations: default (gem)"],
      out.lines.map(&:chomp)
  end

  # An extension a person wrote registers a verb and it is a verb: listed
  # under its own heading, dispatched with its words and options, printing
  # through the same client the shipped verbs use.
  def test_a_verb_an_operator_registered_is_listed_and_dispatched
    install_extension(<<~RUBY, id: "rho.deploy")
      module DeployExtension
        NAME = "rho.deploy"
        def self.register(api)
          api.register_command("deploy", usage: "deploy TARGET", description: "Ship it",
            options: { dry: { type: :boolean, default: false, desc: "Only say what would ship" } }) do |cli, (target), options|
            cli.out.puts "deploying \#{target}\#{options[:dry] ? " (dry)" : ""} from \#{cli.class}"
          end
        end
      end
    RUBY

    listed, status = run_rho("help")
    assert_equal 0, status
    assert_match(/^Extension rho\.deploy:\n\s+rho deploy TARGET\s+# Ship it/, listed)

    out, status = run_rho("deploy", "prod", "--dry", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    assert_equal "deploying prod (dry) from Rho::Cli::Terminal\n", out
  end

  # THOR'S SPELLING (thor.rb `normalize_command_name`: "treat foo-bar as
  # foo_bar"): a verb typed with hyphens dispatches to the method spelled
  # with underscores. A hyphenated verb an extension registers (rho-acp-
  # client's `acp-agents`) must land on that spelling, or `rho help` lists a
  # verb the dispatcher cannot find.
  def test_a_hyphenated_verb_an_extension_registered_is_dispatched
    install_extension(<<~RUBY, id: "rho.ship")
      module ShipItExtension
        NAME = "rho.ship"
        def self.register(api)
          api.register_command("ship-it", usage: "ship-it TARGET", description: "Ship it") do |cli, (target), _options|
            cli.out.puts "shipping \#{target}"
          end
        end
      end
    RUBY

    listed, status = run_rho("help")
    assert_equal 0, status
    assert_match(/^Extension rho\.ship:\n\s+rho ship-it TARGET\s+# Ship it/, listed)

    out, status = run_rho("ship-it", "prod", "--nexus-url", "https://nexus.example")
    assert_equal 0, status, out
    assert_equal "shipping prod\n", out
  end

  # The spelling rule cuts both ways: `run-prompt` is the method `run` lands
  # on (`map "run" => :run_prompt`), so a hyphenated claim on it is the same
  # squat as claiming `status`, refused by the same sentence.
  def test_an_extension_claiming_a_verbs_method_by_its_hyphenated_spelling_is_a_load_error
    install_extension(<<~RUBY, id: "rho.squatter")
      module SquatterExtension
        NAME = "rho.squatter"
        def self.register(api)
          api.register_command("run-prompt") { |_cli, _args, _options| nil }
        end
      end
    RUBY

    out, status = run_rho("help")

    assert_equal 1, status
    assert_equal "rho: rho.squatter registers `run-prompt`, which is already a verb\n", out
  end

  # ONE OWNER PER VERB: an extension claiming a core verb is refused at
  # load, in one sentence, rather than quietly replacing it.
  def test_an_extension_claiming_a_verb_that_exists_is_a_load_error
    install_extension(<<~RUBY, id: "rho.squatter")
      module SquatterExtension
        NAME = "rho.squatter"
        def self.register(api)
          api.register_command("status") { |_cli, _args, _options| nil }
        end
      end
    RUBY

    out, status = run_rho("help")

    assert_equal 1, status
    assert_equal "rho: rho.squatter registers `status`, which is already a verb\n", out
  end

  # `--url` belongs to rho's own address, so the Nexus flag is
  # --nexus-url. A person reaches for --url out of habit and must be told what
  # to use, on any verb, not shown a parser error.
  def test_the_reserved_url_flag_names_its_replacement_on_every_verb
    %w[status connect server version env].each do |verb|
      out, status = run_rho(verb, "--url", "https://nexus.example")

      assert_equal 1, status, "#{verb} --url must fail"
      assert_match(/--url is reserved/, out, "#{verb} must say why")
      assert_match(/--nexus-url/, out, "#{verb} must name the replacement")
    end
  end

  def test_the_reserved_flag_is_caught_in_its_joined_form_too
    _out, status = run_rho("status", "--url=https://nexus.example")

    assert_equal 1, status
  end

  # One sentence and a non-zero status. A backtrace here is a bug report the
  # reader cannot act on.
  def test_a_refused_argument_is_one_sentence_not_a_backtrace
    out, status = run_rho("status", "--nexus-url", "notaurl")

    assert_equal 1, status
    assert_match(/\Arho status: /, out)
    assert_equal 1, out.lines.length, "expected one line, got:\n#{out}"
    refute_match(/\.rb:\d+/, out)
  end

  # `exe/rho` states the contract — one sentence, never a backtrace — and the
  # test above pins it for a refused ARGUMENT. This pins it for the failure a
  # human is far more likely to hit: a daemon that was there for the liveness
  # probe and gone by the next request. Net::HTTP raises EOFError /
  # SystemCallError for that, neither of which is a `Rho::Error`, so they used
  # to escape the rescue entirely.
  #
  # Answering /healthz is what makes this the interesting case: an endpoint that
  # refuses outright is filtered by `running_daemon` and never reaches the code
  # under test.
  def test_a_daemon_that_dies_after_the_liveness_probe_is_one_sentence_not_a_backtrace
    announce(endpoint: inference_request_endpoint)

    out, status = run_rho("status", "--nexus-url", "https://nexus.example")

    assert_equal 1, status, "a daemon that stopped answering is a failure, not a quiet success"
    # `status` prints which Nexus this home is bound to before it looks for a
    # daemon, so that line is legitimately there; the failure is what follows.
    failure = out.lines.grep(/\Arho status: /)
    assert_equal 1, failure.length, "expected one refusal sentence, got:\n#{out}"
    assert_match(/local daemon/, failure.first)
    # A frame, not merely a file and a line: this subprocess makes a real HTTP
    # request, and Ruby's own `HTTP_PROXY is discouraged` warning cites
    # `net/http.rb:1897`, which is not a backtrace.
    refute_match(/:\d+:in /, out, "expected no backtrace, got:\n#{out}")
  end

  def test_the_console_command_prints_the_public_login_url
    announce(endpoint: routed_endpoint(
      "GET /console" => [[200, { "url" => "http://127.0.0.1:7717" }]]
    ))

    out, status = run_rho("console", "--nexus-url", "https://nexus.example")

    assert_equal 0, status, out
    assert_match(%r{^console: http://127\.0\.0\.1:7717$}, out)
    assert_includes out, "Sign in with Nexus to open this rho."
  end

  # Answers the liveness probe once, then closes every later connection without
  # answering. It lives in this process; the subprocess under test dials it.
  def inference_request_endpoint
    served = 0
    serve do |client, _request|
      served += 1
      answer(client, 200, {
        "status" => "ok",
        "version" => Rho::VERSION,
        "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION,
      }) if served == 1
    end
  end

  # A fresh RHO_HOME has no connection, and saying so is a success: "not
  # connected" is an answer, not a failure.
  def test_status_on_a_fresh_home_reports_disconnected_and_succeeds
    out, status = run_rho("status", "--nexus-url", "https://nexus.example")

    assert_equal 0, status
    assert_match(/not connected/, out)
  end
end
