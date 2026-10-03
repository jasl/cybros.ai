require "test_helper"
require "digest"
require "monitor"
require "tmpdir"

# THE SERVERS TABLE: the
# editor's MCP servers per anchor, held as the one registrar's SET —
# bound, re-bound under the digest gate, replaced, cleared, dropped at
# the anchor's end and at shutdown — judged for name collisions against
# the boot table and the other anchors, rendered for the announcement
# and the declaration, and answered to the runner's agent slot as its
# `extras` (`call`, `owner_of`, `names`). Against a set double: no
# process, no socket.
class EnvironmentsServersTest < Minitest::Test
  Servers = Rho::Environments::Servers

  PROFILE = { "kind" => "read_only", "destructive" => false, "world" => "open",
              "idempotency" => "none", "reconciliation" => "none" }.freeze
  SCHEMA = { "type" => "object", "properties" => { "q" => { "type" => "string" } } }.freeze

  class Log
    attr_reader :events

    def initialize = @events = []

    %i[debug info warn error].each do |level|
      define_method(level) { |event, **fields| @events << [event.to_s, fields] }
    end

    def named(event) = @events.select { |name, _| name == event }.map(&:last)
  end

  # The registrar's SET: the classes, the report rows, the digest, and a
  # `close` that counts.
  class FakeSet
    attr_reader :classes, :report, :digest, :closes

    def initialize(classes:, report:, digest: "set")
      @classes = classes
      @report = report
      @digest = digest
      @closes = 0
    end

    def close = @closes += 1
  end

  # A curated class as rho-mcp builds one: `server:` is its `SERVER_KEY`,
  # the report row it belongs to (the seam's contract); none for a class
  # the boot table serves, or for the seam-violation pin.
  def tool_class(name, server: nil, description: "does #{name}", schema: SCHEMA, profile: PROFILE)
    Class.new do
      const_set(:NAME, name)
      const_set(:DESCRIPTION, description)
      const_set(:SCHEMA, schema)
      const_set(:EFFECT_PROFILE, profile)
      const_set(:SERVER_KEY, server) if server
      define_singleton_method(:inspect) { "Tool[#{name}]" }
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |_args| Rho::Runner::Result.ok(name) }
    end
  end

  def setup
    @log = Log.new
    @opened = []
    @sets = []
  end

  def entry(name, command: "fx", env: [{ "name" => "TOKEN", "value" => "hunter2" }])
    { "name" => name, "command" => command, "args" => [], "env" => env }
  end

  # The registrar: two classes per entry by default, or the block's own;
  # a nameless entry is the registrar's ArgumentError (the door's 400).
  def registrar(&build)
    build ||= lambda do |entries|
      raise ArgumentError, "a server entry needs a name" unless entries.all? { |row| row["name"].is_a?(String) }

      FakeSet.new(
        classes: entries.flat_map do |row|
          [tool_class("mcp__#{row["name"]}__lookup", server: row["name"]), tool_class("mcp__#{row["name"]}__paths", server: row["name"])]
        end,
        report: entries.map { |row| { name: row["name"], state: "connected", fault: nil, transport: "stdio" } }
      )
    end
    Rho::Extensions::Registrar.new(extension: "rho.mcp", handler: lambda { |anchor, entries|
      @opened << [anchor, entries]
      build.call(entries).tap { |set| @sets << set }
    })
  end

  def boot_table(*extra_classes)
    extension = Module.new do
      const_set(:NAME, "rho.boot")
      define_singleton_method(:register) { |api| extra_classes.each { |klass| api.register_tool(klass) } }
    end
    Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, extension]).registry
  end

  # `registrar: nil` is a daemon nobody registered on; the block, when
  # given, builds each bind's set in place of the default two-class one.
  def servers(registrar: :default, served: boot_table, &build)
    registrar = self.registrar(&build) if registrar == :default
    Servers.new(monitor: Monitor.new, log: @log, registrar: registrar, served: served)
  end

  # ---- the registrar ----

  def test_no_registrar_answers_422_mcp_unavailable_and_serves_nothing
    table = servers(registrar: nil)

    refusal = table.bind("c-1", [entry("fx")])

    assert_kind_of Rho::Daemon::Refusal, refusal
    assert_equal [422, "mcp_unavailable"], [refusal.status, refusal.code]
    refute_predicate table, :registrar?
    assert_empty table.report("c-1")
    assert_equal [[], nil], table.call("c-1")
    assert_empty table.names
    assert_empty table.announcement
  end

  # ---- bind, no-op, replace, clear ----

  def test_a_bind_holds_the_set_and_serves_its_classes_report_and_announcement
    table = servers

    bound = table.bind("c-1", [entry("fx")])

    assert_kind_of Servers::Bound, bound
    assert bound.changed
    assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }], bound.report
    assert_equal bound.report, table.report("c-1")
    assert_equal [["c-1", [entry("fx")]]], @opened, "the list exactly as received"
    classes, digest = table.call("c-1")
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], classes.map { |klass| klass::NAME }
    assert_equal Servers.digest([entry("fx")]), digest
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], table.names
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], table.names_for("c-1")
    assert_empty table.names_for("c-9")
    assert_equal "c-1", table.owner_of("mcp__fx__lookup")
    assert_nil table.owner_of("mcp__fx__nobody")
    announced = table.announcement
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], announced.map { |row| row.fetch("name") }
    assert_equal({ "name" => "mcp__fx__lookup", "effect_profile" => PROFILE, "description" => "does mcp__fx__lookup",
                   "input_schema" => SCHEMA }, announced.first, "the registry's own rendering (`Entry#announcement`)")
    assert_equal announced, table.announcement_for("c-1")
    assert_empty table.announcement_for(nil)
    assert_equal 1, @log.named("mcp_servers.bound").length
    refute_includes @log.events.inspect, "hunter2", "no line carries an entry"
  end

  def test_an_equal_list_is_a_no_op_and_a_down_row_stays_down_while_a_moved_list_replaces_the_set
    table = servers { |entries| FakeSet.new(classes: [tool_class("mcp__#{entries.first["name"]}__lookup", server: entries.first["name"])],
      report: [{ name: entries.first["name"], state: "down", fault: "exit 1", transport: "stdio" }]) }
    table.bind("c-1", [entry("fx")])
    first = @sets.fetch(0)

    again = table.bind("c-1", [entry("fx", env: [{ "name" => "TOKEN", "value" => "rotated" }])])

    refute again.changed, "the same names, launch and env KEYS: the held set"
    assert_equal "down", again.report.first[:state], "a re-list is a boot: the down row stays down"
    assert_equal 1, @opened.length, "the registrar was not asked again"
    assert_equal 0, first.closes

    moved = table.bind("c-1", [entry("fx", command: "fx2")])

    assert moved.changed
    assert_equal 1, first.closes, "the held set closed FIRST"
    assert_equal 2, @opened.length
    assert_same @sets.fetch(1), table["c-1"].set
    assert_equal 1, @log.named("mcp_servers.closed").count { |fields| fields[:reason] == "replaced" }

    cleared = table.bind("c-1", [])

    assert cleared.changed
    assert_empty cleared.report
    assert_equal 1, @sets.fetch(1).closes
    assert_nil table["c-1"]
    assert_equal [[], nil], table.call("c-1")
    refute table.bind("c-1", []).changed, "nothing held: nothing changed"
  end

  def test_the_digest_reads_names_launches_and_env_or_header_keys_never_values
    stdio = entry("fx", env: [{ "name" => "A", "value" => "1" }])

    assert_equal Servers.digest([stdio]), Servers.digest([entry("fx", env: [{ "name" => "A", "value" => "2" }])]), "a value moved: equal"
    refute_equal Servers.digest([stdio]), Servers.digest([entry("fx", env: [{ "name" => "B", "value" => "1" }])]), "a key moved"
    refute_equal Servers.digest([stdio]), Servers.digest([entry("fx", command: "other")])
    refute_equal Servers.digest([stdio]), Servers.digest([entry("gx")])
    refute_equal Servers.digest([stdio]), Servers.digest([stdio.merge("args" => ["--x"])])
    http = { "type" => "http", "name" => "hx", "url" => "http://127.0.0.1:9/mcp", "headers" => [{ "name" => "Authorization", "value" => "s" }] }
    assert_equal Servers.digest([http]), Servers.digest([http.merge("headers" => [{ "name" => "Authorization", "value" => "t" }])])
    refute_equal Servers.digest([http]), Servers.digest([http.merge("url" => "http://127.0.0.1:10/mcp")])
    assert_kind_of String, Servers.digest([1, nil, "x"]), "a malformed list digests; the registrar refuses it"

    table = servers
    table.bind("c-1", [stdio])
    one = table.digest
    table.bind("c-2", [entry("gx")])
    refute_equal one, table.digest, "the table's digest moves when any anchor's set moves"
  end

  # ---- the registrar's refusal ----

  def test_a_malformed_entry_is_the_registrars_argument_error_answered_as_400
    table = servers { |entries| raise ArgumentError, "a server entry needs a name" if entries.any? { |row| row["name"].nil? }
      FakeSet.new(classes: [], report: []) }
    table.bind("c-1", [entry("fx")])

    refusal = table.bind("c-1", [{ "command" => "x" }])

    assert_kind_of Rho::Daemon::Refusal, refusal
    assert_equal [400, "malformed_body", "a server entry needs a name"], [refusal.status, refusal.code, refusal.message]
    assert_nil table["c-1"], "the held set was closed before the registrar was asked: the anchor holds nothing"
    assert_equal 1, @sets.fetch(0).closes
    assert_equal 1, @log.named("mcp_servers.malformed").length
  end

  # A registrar that will not open a set at all — its own
  # `Rho::Runner::Error`, rho-mcp's `Closed` once its shutdown ladder ran
  # — is the door's 503 `daemon_stopping`, the daemon's own sentence (it
  # does not know rho-mcp's classes); the anchor holds nothing, nothing is
  # announced, and over a held set the held set went first.
  # rho-mcp's `Closed` by shape: a `Rho::Runner::Error` the daemon does
  # not know by class.
  class Closed < Rho::Runner::Error; end

  def test_a_registrar_that_will_not_open_a_set_is_answered_as_503_daemon_stopping_and_nothing_is_held
    table = servers { |entries| raise Closed, "the mcp host is shutting down" if entries.first["command"] == "closing"
      FakeSet.new(classes: [tool_class("mcp__fx__lookup", server: "fx")],
        report: [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }]) }

    refusal = table.bind("c-1", [entry("fx", command: "closing")])

    assert_kind_of Rho::Daemon::Refusal, refusal
    assert_equal [503, "daemon_stopping", "The local daemon is stopping"], [refusal.status, refusal.code, refusal.message]
    assert_nil table["c-1"]
    assert_empty table.names
    assert_empty table.announcement
    assert_equal [[], nil], table.call("c-1")
    assert_equal [["c-1", "EnvironmentsServersTest::Closed", "the mcp host is shutting down"]],
      @log.named("mcp_servers.registrar_closed").map { |f| f.values_at(:anchor, :error_class, :detail) }

    assert table.bind("c-1", [entry("fx")]).changed
    assert_equal %w[mcp__fx__lookup], table.names

    refusal = table.bind("c-1", [entry("fx", command: "closing")])

    assert_equal [503, "daemon_stopping"], [refusal.status, refusal.code]
    assert_equal 1, @sets.fetch(0).closes, "the held set was closed before the registrar was asked"
    assert_nil table["c-1"]
    assert_empty table.names
    assert_empty table.announcement
  end

  # ---- name collisions ----

  # A name the boot table serves faults the ROW for this anchor — every
  # class of the row dropped, the report row `down` with the owner — and
  # the anchor's other rows stand; a class the registry would refuse is
  # faulted with its sentence, never raised.
  def test_a_name_the_boot_table_serves_faults_the_row_and_drops_its_classes
    table = servers(served: boot_table(tool_class("mcp__fx__lookup")))

    bound = table.bind("c-1", [entry("fx"), entry("gx")])

    assert_equal [{ name: "fx", state: "down", fault: "name taken by the boot table (rho.boot)", transport: "stdio" },
                  { name: "gx", state: "connected", fault: nil, transport: "stdio" }], bound.report
    assert_equal %w[mcp__gx__lookup mcp__gx__paths], table.names_for("c-1"), "fx's paths went with its row"
    assert_nil table.owner_of("mcp__fx__paths")
    taken = @log.named("mcp_servers.name_taken")
    assert_equal [["c-1", "mcp__fx__lookup", "the boot table (rho.boot)"]], taken.map { |f| f.values_at(:anchor, :tool, :owner) }

    bad = tool_class("mcp__hx__lookup", server: "hx", profile: { "kind" => "readonly" })
    refused = servers { |_entries| FakeSet.new(classes: [bad], report: [{ name: "hx", state: "connected", fault: nil, transport: "stdio" }]) }
    bound = refused.bind("c-2", [entry("hx")])
    assert_equal "down", bound.report.first[:state]
    assert_match(/must declare EFFECT_PROFILE/, bound.report.first[:fault])
    assert_empty refused.names_for("c-2")
  end

  # rho-mcp's public name for a tool of "My Server":
  # every byte outside `[A-Za-z0-9_-]` folded to `_`, `_` + the first 12
  # hex of SHA-256("<server>\0<raw>") appended — `Naming.tool` byte for
  # byte, so the row's name is not the public name's prefix.
  def folded(server, raw)
    "mcp__#{server.gsub(/[^A-Za-z0-9_-]/, "_")}__#{raw}_#{Digest::SHA256.hexdigest("#{server}\0#{raw}")[0, 12]}"
  end

  # THE ROW IS THE CLASS'S `SERVER_KEY`, never its name's prefix: a taken
  # name under a folded row faults THAT row — the report row `down` with
  # the owner — and every class of the row goes with it, the class whose
  # name was not taken included.
  def test_a_taken_name_under_a_folded_row_faults_the_row_by_its_server_key_and_drops_every_class_of_it
    echo = folded("My Server", "echo")
    paths = folded("My Server", "paths")
    assert_match(/\Amcp__My_Server__echo_[0-9a-f]{12}\z/, echo)
    table = servers(served: boot_table(tool_class(echo, schema: { "type" => "object" }))) do |_entries|
      FakeSet.new(classes: [tool_class(echo, server: "My Server"), tool_class(paths, server: "My Server")],
        report: [{ name: "My Server", state: "connected", fault: nil, transport: "stdio" }])
    end

    bound = table.bind("c-1", [entry("My Server")])

    assert_equal [{ name: "My Server", state: "down", fault: "name taken by the boot table (rho.boot)", transport: "stdio" }], bound.report
    assert_equal bound.report, table.report("c-1")
    assert_empty table.names_for("c-1"), "every class of the row went, the untaken #{paths} with it"
    assert_nil table.owner_of(paths)
    assert_empty table.announcement
    assert_equal [["c-1", echo, "the boot table (rho.boot)", "My Server"]],
      @log.named("mcp_servers.name_taken").map { |f| f.values_at(:anchor, :tool, :owner, :row) }
  end

  # A class without `SERVER_KEY` is the registrar breaking the seam: raised
  # by name (a `RegistrationError`, as a registration the loader refuses
  # is), never faulted under a guessed row — the set it came in closed on
  # the way out, the anchor holding nothing.
  def test_a_class_without_server_key_is_a_seam_violation_raised_by_name_and_the_set_is_closed
    table = servers { |_entries| FakeSet.new(classes: [tool_class("mcp__fx__lookup", server: "fx"), tool_class("mcp__fx__paths")],
      report: [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }]) }

    error = assert_raises(Rho::Runner::Extensions::RegistrationError) { table.bind("c-1", [entry("fx")]) }

    assert_equal "mcp__fx__paths carries no SERVER_KEY: a conversation server's class names its row (rho.mcp)", error.message
    assert_nil table["c-1"]
    assert_empty table.names
    assert_equal 1, @sets.fetch(0).closes, "the set was closed on the way out"
    assert_equal [["c-1", error.message]], @log.named("mcp_servers.seam_violation").map { |f| f.values_at(:anchor, :detail) }
    assert_equal [["c-1", "seam_violation"]], @log.named("mcp_servers.closed").map { |f| f.values_at(:anchor, :reason) }
    assert_empty @log.named("mcp_servers.name_taken"), "nothing was judged"
  end

  # The SAME name with the SAME entry from two anchors is ONE announced
  # entry serving both — each anchor's own class answers its own calls —
  # while a DIFFERENT entry under a taken name faults the later row.
  def test_the_same_entry_from_two_anchors_is_one_announced_entry_and_a_different_one_is_faulted
    table = servers
    table.bind("c-1", [entry("fx")])
    table.bind("c-2", [entry("fx")])

    assert_equal %w[mcp__fx__lookup mcp__fx__paths], table.names, "a name once"
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], table.announcement.map { |row| row.fetch("name") }
    assert_equal %w[mcp__fx__lookup mcp__fx__paths], table.names_for("c-2"), "the second window serves too"
    refute_same table.call("c-1").first.first, table.call("c-2").first.first, "each anchor's OWN class"
    assert_equal "c-1", table.owner_of("mcp__fx__lookup"), "the first holder names the owner"
    assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }], table.report("c-2")

    other = Servers.new(monitor: Monitor.new, log: @log, registrar: different_registrar, served: boot_table)
    other.bind("c-1", [entry("fx")])
    bound = other.bind("c-2", [entry("fx")])

    assert_equal [{ name: "fx", state: "down", fault: "name taken by conversation c-1", transport: "stdio" }], bound.report
    assert_empty other.names_for("c-2")
    assert_equal %w[mcp__fx__lookup], other.names
  end

  # A registrar answering a DIFFERENT schema under the same name on its
  # second bind — two windows on two versions of one server.
  def different_registrar
    calls = 0
    Rho::Extensions::Registrar.new(extension: "rho.mcp", handler: lambda { |_anchor, entries|
      calls += 1
      schema = calls == 1 ? SCHEMA : { "type" => "object" }
      FakeSet.new(classes: [tool_class("mcp__#{entries.first["name"]}__lookup", server: entries.first["name"], schema: schema)],
        report: entries.map { |row| { name: row["name"], state: "connected", fault: nil, transport: "stdio" } })
    })
  end

  # ---- the ends ----

  def test_host_ended_drops_the_anchors_set_once_and_shutdown_closes_every_set
    table = servers
    table.bind("c-1", [entry("fx")])
    table.bind("c-2", [entry("gx")])

    assert table.host_ended("c-1")
    assert_equal 1, @sets.fetch(0).closes
    refute table.host_ended("c-1"), "already gone"
    assert_equal 1, @sets.fetch(0).closes
    assert_equal %w[mcp__gx__lookup mcp__gx__paths], table.names
    assert_equal [["c-1", "host_ended"]], @log.named("mcp_servers.closed").map { |f| f.values_at(:anchor, :reason) }

    table.bind("c-3", [entry("hx")])
    table.shutdown

    assert_equal [1, 1], [@sets.fetch(1).closes, @sets.fetch(2).closes]
    assert_empty table.names
    assert_nil table["c-2"]
    assert_equal 2, @log.named("mcp_servers.closed").count { |f| f[:reason] == "shutdown" }

    failing = servers { |_entries| FakeSet.new(classes: [], report: []).tap { |set| set.define_singleton_method(:close) { raise "hung" } } }
    failing.bind("c-4", [entry("ix")])
    assert failing.host_ended("c-4"), "a set that cannot close still leaves the table"
    assert_equal 1, @log.named("mcp_servers.close_failed").length
  end

  # ---- through the daemon's tables ----

  # `Environments` hands the table to the door (`bind_servers`, the
  # daemon told on a change alone), to the runner's agent slot (its
  # `extras`), to the live table (`mcp:` rows), and lets it go with the
  # host (`host_ended` answers that a set left) and at `shutdown`.
  def test_the_environments_tables_bind_report_and_drop_the_servers_and_tell_the_daemon_on_a_change
    Dir.mktmpdir("rho-servers") do |root|
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(root, "home"))
      home.prepare
      project = File.join(root, "project")
      FileUtils.mkdir_p(project)
      changed = 0
      registry = boot_table
      table = Rho::Environments.new(
        home: home, config: Rho::Config.from_hash({}), registry: registry, log: @log, clock: -> { Time.now },
        booted_at: "2026-09-17T08:00:00Z", default_root: -> { project }, member_plane: ->(**) { nil },
        own_runner: ->(_id) { true }, learn_runner: ->(_document) { nil }, spawn: ->(&work) { work.call },
        registrar: registrar, served: registry, servers_changed: -> { changed += 1 }
      )
      binding = Rho::Runner::Environment::Binding.new(root: project, directories: [], anchor: "c-1")
      table.remember_copy("c-1", binding)

      bound = table.bind_servers("c-1", [entry("fx")])

      assert bound.changed
      assert_equal 1, changed
      assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }], table.servers_report("c-1")
      refute table.bind_servers("c-1", [entry("fx")]).changed
      assert_equal 1, changed, "an equal list tells the daemon nothing"
      host = Rho::Host::Conversation.new(public_id: "c-1")
      assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "stdio" }], table.listing([host]).fetch(0).fetch(:mcp)
      assert_same table.servers, table.agent_toolsets(registry).extras, "the agent slot's extras are the table"
      assert_kind_of Rho::Runner::Toolsets, table.agent_toolsets(registry)

      assert table.host_ended("c-1")
      assert_equal 2, changed
      assert_empty table.servers_report("c-1")
      assert_empty table.listing([host]).fetch(0).fetch(:mcp)
      refute table.host_ended("c-1")
      assert_equal 2, changed

      table.bind_servers("c-1", [entry("gx")])
      table.shutdown
      assert_empty table.servers.names
      assert_equal 1, @sets.last.closes

      refusal = table.bind_servers("c-1", [{ "command" => "x" }])
      assert_kind_of Rho::Daemon::Refusal, refusal
      assert_equal 3, changed, "the refused list's predecessor: none held, nothing changed"

      table.bind_servers("c-1", [entry("hx")])
      assert_equal 4, changed
      refusal = table.bind_servers("c-1", [{ "command" => "x" }])
      assert_kind_of Rho::Daemon::Refusal, refusal
      assert_equal 5, changed, "a refused list over a held set: the held set went (closed first) and the daemon is told"
      assert_equal 1, @sets.last.closes
      assert_empty table.servers_report("c-1")
      assert_empty table.servers.names
    end
  end
end
