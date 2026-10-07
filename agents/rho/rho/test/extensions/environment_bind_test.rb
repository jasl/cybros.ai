require "test_helper"
require "tmpdir"

# THE HIDDEN RUNNER TOOL `environment_bind`: how a host elsewhere tells this runner slot
# a conversation's root set over the executor call_tool. `checkpoint_restore`'s posture — served
# on the runner address, described to nobody, announced schema-less, hidden by NAME from
# every declaration — with an HONEST write-kind profile (a runner-state write is a write
# in the kernel's vocabulary) and exempt from the checkpoint capture by name. Bound to
# the daemon's tables the settled way (`Todo::Write.bind`): a late-bound `environments:`
# member on `Extensions::Host`, nil under a loader with no daemon.
class EnvironmentBindTest < Minitest::Test
  Bind = Rho::Extensions::Environment::Tools::Bind

  def setup
    @root = Dir.mktmpdir("rho-bind")
    @project = File.join(@root, "project")
    FileUtils.mkdir_p(@project)
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home"))
    @home.prepare
    @log = Rho::Log.to_file(File.join(@root, "rho.log"))
    @environments = Rho::Environments.new(
      home: @home, config: Rho::Config.from_hash({}),
      registry: Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry,
      log: @log, clock: -> { Time.now }, booted_at: "2026-09-17T08:00:00Z", default_root: -> { @project },
      member_plane: ->(**) { nil }, own_runner: ->(_id) { false }, learn_runner: ->(_document) { nil },
      spawn: ->(&work) { work.call }
    )
    Bind.bind(environments: -> { @environments }, log: @log)
  end

  def teardown
    Bind.bind(environments: nil, log: nil)
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def call(input) = Bind.new(env: nil).call(input)

  def input(root = @project, directories: [], anchor: "c-1", conversation: "c-1")
    { "conversation_public_id" => conversation, "root" => root, "directories" => directories, "anchor" => anchor }
  end

  # THE POSTURE: hidden by name, announced schema-less, an honest write.
  def test_the_tool_is_described_to_nobody_hidden_by_name_and_an_honest_write
    assert_equal "environment_bind", Bind::NAME
    assert_nil Bind::DESCRIPTION
    assert_equal %w[conversation_public_id root], Bind::SCHEMA.fetch("required")
    assert_equal %w[anchor conversation_public_id directories root], Bind::SCHEMA.fetch("properties").keys.sort
    assert_equal({ "kind" => "write", "destructive" => false, "effect_scope" => "closed", "idempotency" => "intrinsic",
                   "reconciliation" => "none" }, Bind::EFFECT_PROFILE, "an honest write; the kernel's word for a whole replacement")
    refute Bind.const_defined?(:TIMEOUT_MS), "the runner's announced park governs the row, never a clock of its own"
    assert_includes Rho::RunDeclaration.undeclared, Bind::NAME, "no model is offered it"
    # THE CAPTURE EXEMPTION, by name across the gem boundary: rho-runner
    # cannot see this constant, so it names the string; pinned here.
    assert_includes Rho::Runner::Extensions::Checkpoints::EXEMPT, Bind::NAME,
      "an honest write-kind call would snapshot the runner's default root per call_tool without it"
  end

  # REGISTERED ON THE RUNNER ADDRESS where the host serves one: full and
  # runner mode announce it (name and profile alone); agent mode registers
  # no runner tool and refuses nothing.
  def test_it_registers_on_the_runner_address_in_full_and_runner_mode_and_not_in_agent_mode
    %w[full runner].each do |mode|
      host = Rho::Extensions::Host.new(home: @home, log: nil, clock: -> { Time.now },
        config: Rho::Config.from_hash({ "mode" => mode }), processes: nil)
      loaded = Rho::Extensions.load(host: host, extensions: [Rho::Extensions::Environment])
      assert_predicate loaded, :ok?, loaded.failures.inspect
      entry = loaded.registry.serving(:runner).entries.find { |candidate| candidate.name == Bind::NAME }
      refute_nil entry, "#{mode} mode serves the runner address"
      assert_equal %w[name effect_profile], entry.announcement.keys, "announced schema-less"
    end

    host = Rho::Extensions::Host.new(home: @home, log: nil, clock: -> { Time.now },
      config: Rho::Config.from_hash({ "mode" => "agent" }), processes: nil)
    loaded = Rho::Extensions.load(host: host, extensions: [Rho::Extensions::Environment])
    assert_predicate loaded, :ok?
    assert_empty loaded.registry.names, "agent mode serves no runner tool"
    assert_nil host.environments, "nil under a loader with no daemon"
  end

  # THE ANSWER: a root on this host applies and resolves; one
  # absent applies unresolved (placement zero there, one notice); a root
  # under a protected root is refused as data — the incubation denies
  # stand in every mode; the received binding is what the slot resolves.
  def test_it_writes_the_received_table_and_answers_applied_resolved_and_this_daemons_boot
    result = call(input)

    refute_predicate result, :is_error, result.content
    assert_equal({ "applied" => true, "resolved" => true, "booted_at" => "2026-09-17T08:00:00Z" }, result.structured_content)
    assert_includes result.content, @project
    assert_equal Rho::Runner::Environment::Binding.new(root: @project, directories: [], anchor: "c-1"),
      @environments.binding_for("c-1")
    assert_match(/event=environment\.received .*conversation=c-1/, File.read(File.join(@root, "rho.log"), encoding: "UTF-8"))

    absent = call(input(File.join(@root, "absent"), conversation: "c-2", anchor: "c-2"))
    refute_predicate absent, :is_error
    assert_equal false, absent.structured_content.fetch("resolved")
    assert_includes absent.content, "not a directory on this host"
    assert_equal File.join(@root, "absent"), @environments.binding_for("c-2").root, "applied all the same"

    refused = call(input(Rho.root, conversation: "c-3", anchor: "c-3"))
    assert_predicate refused, :is_error
    assert_includes refused.content, "protected_root"
    assert_nil @environments.binding_for("c-3"), "nothing received"

    directory = call(input(@project, directories: [File.join(@home.root, "settings.json")], conversation: "c-4", anchor: "c-4"))
    assert_predicate directory, :is_error
    assert_includes directory.content, "protected_root"
  end

  # Under a loader with no daemon there are no tables to write: an error
  # the call_tool's caller reads, never a raise.
  def test_without_the_daemons_tables_it_answers_an_error
    Bind.bind(environments: nil, log: nil)

    result = call(input)

    assert_predicate result, :is_error
    assert_includes result.content, "environment_unavailable"
  end
end
