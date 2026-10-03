require "test_helper"

# THE PLACEMENTS: the environment is a per-conversation
# VALUE the runner resolves at dispatch — the HOST resolves it (the daemon's
# `Environments`, handed in as `resolver:`), the runner RECEIVES a `Binding`
# and answers ONE frozen `ToolEnv` + toolset per ROOT SET, never per
# conversation. Placement zero is the daemon's default root; a row that
# names no conversation, a binding nobody wrote, a root absent on this host
# or under a protected one all land there. The tools are byte-identical
# across placements: only the env differs.
class ToolsetsTest < Minitest::Test
  Toolsets = Rho::Runner::Toolsets
  Placement = Rho::Runner::Placement
  Binding = Rho::Runner::Environment::Binding
  Task = CybrosAgent::Api::InboxTask

  class Log
    attr_reader :events

    def initialize = @events = []

    %i[debug info warn error].each do |level|
      define_method(level) { |event, **fields| @events << [event.to_s, fields] }
    end

    def named(event) = @events.select { |name, _| name == event }.map(&:last)
  end

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-toolsets"))
    @work = File.join(@tmp, "work")
    @zero_root = File.join(@tmp, "zero")
    @other = File.join(@tmp, "other")
    @third = File.join(@tmp, "third")
    FileUtils.mkdir_p([@zero_root, @other, @third])
    @log = Log.new
    @queue = Rho::Runner::FileMutationQueue.new
    @processes = Object.new
    @zero = Rho::Runner::ToolEnv.new(
      root: @zero_root, artifacts_dir: Rho::Runner::ToolEnv.artifacts_dir_for(root: @zero_root, work_dir: @work),
      mutation_queue: @queue, processes: @processes, bash_timeout_seconds: 7
    )
    @registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
    @resolved = []
    @opened = []
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def row(key, loop: "loop-1", conversation: "conv-1", parent: nil)
    Task.new(workspace_public_id: "ws-1", kind: "tool_call", agent_loop_public_id: loop, conversation_public_id: conversation,
      parent_public_id: parent, task_key: key, tool_name: "read", tool_input: {}, tool_call_id: "call-#{key}",
      started_at: nil, deadline_at: nil, timeout_ms: nil, claimed: false,
      addressed_to: CybrosAgent::Api::AddressedTo.new(role: "runner", executor_public_id: "ex-1"), scope: nil)
  end

  def binding(root, directories: [], anchor: "conv-1") = Binding.new(root: root, directories: directories, anchor: anchor)

  # The host's resolver: what it was asked is recorded; the table answers.
  def toolsets(table = {}, protected_roots: [], &resolver)
    resolver ||= lambda do |conversation, parent|
      @resolved << [conversation, parent]
      table.fetch(conversation, nil)
    end
    Toolsets.new(
      registry: @registry, zero: @zero, resolver: resolver, work_dir: @work, log: @log,
      checkpoints: ->(root) { @opened << root; Object.new }, protected_roots: protected_roots
    )
  end

  # ---- zero ----

  def test_a_standalone_row_names_no_conversation_and_lands_on_zero_without_asking
    subject = toolsets({ "conv-1" => binding(@other) })

    placement = subject.for(row("t1", conversation: nil))

    assert_same @zero, placement.env
    assert_nil placement.binding
    assert_same subject.zero.toolset, placement.toolset
    assert_empty @resolved, "a standalone loop has nothing to resolve"
    assert_equal @registry.names.sort, subject.names.sort, "the announced set is the registry's"
  end

  def test_a_binding_nobody_wrote_lands_on_zero_and_the_miss_is_memoized_per_loop
    subject = toolsets({})

    first = subject.for(row("t1", loop: "loop-1"))
    second = subject.for(row("t2", loop: "loop-1"))
    other = subject.for(row("t3", loop: "loop-2"))

    assert_same @zero, first.env
    assert_same @zero, second.env
    assert_same @zero, other.env
    assert_equal [["conv-1", nil], ["conv-1", nil]], @resolved,
      "one read per loop: the second claim of loop-1 asked nothing, loop-2 asked again"
  end

  # ---- the placement ----

  def test_the_resolver_is_asked_with_the_rows_conversation_and_parent
    subject = toolsets({ "child" => binding(@other, anchor: "parent") })

    placement = subject.for(row("t1", conversation: "child", parent: "parent"))

    assert_equal [["child", "parent"]], @resolved
    assert_equal "parent", placement.binding.anchor
  end

  def test_two_conversations_on_one_root_set_share_one_env_and_one_toolset
    subject = toolsets({ "conv-1" => binding(@other, anchor: "conv-1"), "conv-2" => binding(@other, anchor: "conv-2") })

    one = subject.for(row("t1", conversation: "conv-1"))
    two = subject.for(row("t2", conversation: "conv-2"))

    assert_same one.env, two.env, "the memo is per root set, never per conversation"
    assert_same one.toolset, two.toolset
    assert_equal @other, one.env.root
    assert_equal "conv-1", one.binding.anchor
    assert_equal "conv-2", two.binding.anchor, "the placement carries the conversation's own record"
    assert_equal [@other], @opened, "the root's store opened once"
    assert_equal 2, @resolved.length, "the host is asked per claim; the placement is what is memoized"
  end

  def test_the_tools_are_byte_identical_across_placements_and_only_the_env_differs
    subject = toolsets({ "conv-1" => binding(@other) })

    placed = subject.for(row("t1"))

    assert_equal subject.zero.toolset.declarations, placed.toolset.declarations
    assert_equal subject.zero.toolset.names, placed.toolset.names
    refute_same subject.zero.env, placed.env
  end

  def test_a_placements_env_is_built_from_zero_with_the_roots_own_captures_and_store
    subject = toolsets({ "conv-1" => binding(@other, directories: [@third]) })

    env = subject.for(row("t1")).env

    assert_predicate env, :frozen?
    assert_equal @other, env.root
    assert_equal [@third], env.directories
    assert_equal @zero_root, env.documents_root, "what was announced loads everywhere"
    assert_equal Rho::Runner::ToolEnv.artifacts_dir_for(root: @other, work_dir: @work), env.artifacts_dir
    assert_same @queue, env.mutation_queue, "ONE queue per runner: two roots never interleave one absolute path"
    assert_same @processes, env.processes
    assert_equal 7, env.bash_timeout_seconds
    refute_nil env.checkpoints
    assert_equal [@other], @opened
  end

  def test_a_root_set_is_keyed_by_its_spelling_so_a_symlinked_root_finds_its_memo
    link = File.join(@tmp, "link")
    File.symlink(@other, link)
    subject = toolsets({ "conv-1" => binding(@other), "conv-2" => binding(link) })

    one = subject.for(row("t1", conversation: "conv-1"))
    two = subject.for(row("t2", conversation: "conv-2"))

    assert_same one.env, two.env, "the memo key is the spelled root set"
  end

  # ZERO'S KEY IS SPELLED TOO: the daemon hands its default root as the
  # operator spelled it (`rho env /var/...` on macOS is `/private/var/...`
  # by real path), and a conversation bound to that same directory by its
  # real path is on ZERO's root set — one env, one toolset, no second store
  # and no second captures digest for the default root.
  def test_a_binding_naming_zeros_own_root_shares_zeros_env_whatever_the_spelling
    link = File.join(@tmp, "zero-link")
    File.symlink(@zero_root, link)
    spelled_by_link = Rho::Runner::ToolEnv.new(
      root: link, artifacts_dir: Rho::Runner::ToolEnv.artifacts_dir_for(root: link, work_dir: @work),
      mutation_queue: @queue, processes: @processes
    )
    subject = Toolsets.new(
      registry: @registry, zero: spelled_by_link, resolver: ->(*) { binding(@zero_root) }, work_dir: @work,
      log: @log, checkpoints: ->(root) { @opened << root; Object.new }
    )

    placement = subject.for(row("t1"))

    assert_same spelled_by_link, placement.env, "the default root at any spelling is zero's env"
    assert_same subject.zero.toolset, placement.toolset
    assert_equal "conv-1", placement.binding.anchor, "and the placement still carries the conversation's record"
    assert_empty @opened, "no second store opened for the default root"
  end

  def test_the_directories_are_part_of_the_root_set
    subject = toolsets({ "conv-1" => binding(@other), "conv-2" => binding(@other, directories: [@third]) })

    one = subject.for(row("t1", conversation: "conv-1"))
    two = subject.for(row("t2", conversation: "conv-2"))

    refute_same one.env, two.env
    refute_same one.toolset, two.toolset, "a second root set is a second toolset over its own env"
    assert_equal one.toolset.declarations, two.toolset.declarations
  end

  def test_the_validator_is_compiled_once_per_entry_and_shared_by_every_placement
    subject = toolsets({ "conv-1" => binding(@other) })

    placed = subject.for(row("t1"))

    assert_same subject.zero.toolset.fetch("read").validator, placed.toolset.fetch("read").validator
  end

  # ---- zero with a notice ----

  def test_a_root_absent_on_this_host_lands_on_zero_and_is_logged_once_per_conversation_and_root
    missing = File.join(@tmp, "gone")
    subject = toolsets({ "conv-1" => binding(missing), "conv-2" => binding(missing) })

    3.times { |index| subject.for(row("t#{index}", loop: "loop-#{index}", conversation: "conv-1")) }
    subject.for(row("t9", conversation: "conv-2"))

    unresolved = @log.named("environment.unresolved")
    assert_equal 2, unresolved.length, "once per (conversation, root)"
    assert_equal [%w[conv-1], %w[conv-2]], unresolved.map { |fields| [fields.fetch(:conversation)] }
    assert_equal missing, unresolved.first.fetch(:root)
    assert_same @zero, subject.for(row("t10", conversation: "conv-1")).env
    assert_empty @opened
  end

  def test_a_root_under_a_protected_root_is_refused_to_zero
    subject = toolsets({ "conv-1" => binding(File.join(@other, "sub")) }, protected_roots: [@other])
    FileUtils.mkdir_p(File.join(@other, "sub"))

    placement = subject.for(row("t1"))

    assert_same @zero, placement.env
    assert_nil placement.binding
    refused = @log.named("environment.refused")
    assert_equal 1, refused.length
    assert_equal "conv-1", refused.first.fetch(:conversation)
    assert_empty @opened
  end

  def test_a_resolver_that_raises_costs_that_claim_zero_and_is_asked_again
    asked = 0
    subject = toolsets do |_conversation, _parent|
      asked += 1
      raise "the member plane is away"
    end

    assert_same @zero, subject.for(row("t1")).env
    assert_same @zero, subject.for(row("t2")).env

    assert_equal 2, asked, "a failure is no Miss: the next claim reads again"
    assert_equal 2, @log.named("environment.unresolved").length
    assert_equal "RuntimeError", @log.named("environment.unresolved").first.fetch(:error_class)
  end

  # ---- fixed ----

  def test_fixed_answers_one_placement_for_every_row_and_the_coding_set_by_default
    subject = Toolsets.fixed(env: @zero)

    placement = subject.for(row("t1", conversation: "conv-1"))

    assert_same @zero, placement.env
    assert_nil placement.binding
    assert_same subject.zero, placement
    assert_equal Rho::Runner::Extensions::Coding::TOOLS.map { |klass| klass::NAME }.sort, subject.names.sort
  end

  def test_fixed_carries_a_hand_built_toolset_with_or_without_an_env
    echo = Rho::Runner::Toolset.new("echo" => Rho::Runner::Toolset::Tool.new(
      name: "echo", description: "echo", parameters: { "type" => "object" }, handler: ->(_a, _c) { nil }
    ))

    bare = Toolsets.fixed(toolset: echo)
    assert_nil bare.for(row("t1")).env
    assert_same echo, bare.for(row("t1")).toolset
    assert_equal ["echo"], bare.names

    placed = Toolsets.fixed(env: @zero, toolset: echo)
    assert_same @zero, placed.for(row("t1")).env
    assert_same echo, placed.zero.toolset
  end

  def test_a_placement_is_a_value
    placement = Placement.new(env: @zero, toolset: Rho::Runner::Toolset.new, binding: nil)

    assert_predicate placement, :frozen?
    assert_nil placement.binding
  end

  # THE PORTS RESOLVER RIDES THE TOOLSETS:
  # the daemon hands one callable keyed by anchor, the run places it on
  # every context beside the placement, and a fixed placement has none.
  def test_the_ports_resolver_is_handed_through_and_a_fixed_placement_has_none
    ports = ->(_anchor) { nil }
    subject = Toolsets.new(registry: @registry, zero: @zero, resolver: ->(_c, _p) { nil }, work_dir: @work, ports: ports)

    assert_same ports, subject.ports
    assert_nil toolsets.ports, "absent by default"
    assert_nil Toolsets.fixed(env: @zero).ports
  end

  # ---- the extras ----

  # A curated class as the host's registrar hands them: the registry's
  # contract, closing over its own connection (here, a name echo).
  def extra_class(name, schema: { "type" => "object", "properties" => { "q" => { "type" => "string" } } })
    Class.new do
      const_set(:NAME, name)
      const_set(:DESCRIPTION, "editor tool #{name}")
      const_set(:SCHEMA, schema)
      const_set(:EFFECT_PROFILE, { "kind" => "read_only", "destructive" => false, "world" => "open",
                                   "idempotency" => "none", "reconciliation" => "none" })
      const_set(:INTERNAL_CLAMP, true)
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |args| Rho::Runner::Result.ok("#{name} on #{@env.root} #{args["q"]}") }
    end
  end

  # The host's table double: anchor → [classes, digest], the owner of a
  # name, every anchor's names. Replaced whole by `sets=`, as the daemon
  # replaces its table.
  class Extras
    attr_accessor :sets
    attr_reader :asked

    def initialize(sets)
      @sets = sets
      @asked = []
    end

    def call(anchor)
      @asked << anchor
      classes, digest = @sets[anchor]
      [Array(classes), digest]
    end

    def owner_of(name) = @sets.find { |_anchor, (classes, _)| classes.any? { |klass| klass::NAME == name } }&.first

    def names = @sets.values.flat_map { |classes, _| classes.map { |klass| klass::NAME } }.uniq
  end

  def with_extras(table, extras, **options)
    Toolsets.new(
      registry: @registry, zero: @zero, resolver: ->(conversation, _parent) { table.fetch(conversation, nil) },
      work_dir: @work, log: @log, extras: extras, **options
    )
  end

  def context(tool_env)
    Rho::Runner::ExecutionContext.new(task_key: "t", agent_loop_public_id: "loop-1", tool_env: tool_env)
  end

  def test_an_anchors_extras_join_its_placement_over_the_placements_env_and_no_other_anchors
    lookup = extra_class("mcp__fx__lookup")
    extras = Extras.new("conv-1" => [[lookup], "d1"])
    subject = with_extras({ "conv-1" => binding(@other, anchor: "conv-1"), "conv-2" => binding(@other, anchor: "conv-2") }, extras)

    one = subject.for(row("t1", conversation: "conv-1"))
    two = subject.for(row("t2", conversation: "conv-2"))

    assert_equal (@registry.names + ["mcp__fx__lookup"]).sort, one.toolset.names.sort, "the registry's plus the anchor's"
    assert_equal @registry.names.sort, two.toolset.names.sort, "another anchor's placement holds none of them"
    assert_same one.env, two.env, "one env per root set still"
    assert_same one.toolset.fetch("read").validator, two.toolset.fetch("read").validator, "the registry's tools are the memoized placement's"
    tool = one.toolset.fetch("mcp__fx__lookup")
    assert_equal "mcp__fx__lookup on #{@other} x", tool.handler.call({ "q" => "x" }, context(one.env)).content
    assert_equal({ "kind" => "read_only", "destructive" => false, "world" => "open", "idempotency" => "none", "reconciliation" => "none" },
      tool.effect_profile)
    assert tool.internal_clamp
    assert_equal (@registry.names + ["mcp__fx__lookup"]).sort, subject.names.sort, "the announced set carries the extras"
  end

  def test_the_extended_table_is_memoized_per_env_anchor_and_digest_and_a_relisted_set_is_a_new_table
    extras = Extras.new("conv-1" => [[extra_class("mcp__fx__lookup")], "d1"])
    subject = with_extras({ "conv-1" => binding(@other, anchor: "conv-1") }, extras)

    first = subject.for(row("t1"))
    again = subject.for(row("t2"))
    assert_same first.toolset, again.toolset, "the same set: the held table"

    extras.sets = { "conv-1" => [[extra_class("mcp__fx__lookup"), extra_class("mcp__fx__paths")], "d2"] }
    relisted = subject.for(row("t3"))
    refute_same first.toolset, relisted.toolset, "a moved digest is a new table"
    assert_includes relisted.toolset.names, "mcp__fx__paths"

    extras.sets = {}
    cleared = subject.for(row("t4"))
    assert_equal @registry.names.sort, cleared.toolset.names.sort, "a closed set: the registry's alone"
    assert_equal %w[conv-1] * 4, extras.asked, "asked per claim; the table is what is memoized"
  end

  # THE REMOTE-AGENT EDGE: a call from any other
  # conversation — another anchor, a row with no record at all — to a
  # name one anchor's editor serves is answered as data, naming the
  # owner; a name nobody serves is still the run's KeyError.
  def test_a_foreign_anchors_extra_is_answered_as_an_error_result_naming_its_owner
    extras = Extras.new("conv-1" => [[extra_class("mcp__fx__lookup")], "d1"])
    subject = with_extras({ "conv-1" => binding(@other, anchor: "conv-1"), "conv-2" => binding(@third, anchor: "conv-2") }, extras)

    other = subject.for(row("t1", conversation: "conv-2"))
    refused = other.toolset.fetch("mcp__fx__lookup")
    result = refused.handler.call({}, context(other.env))
    assert result.is_error
    assert_equal "mcp__fx__lookup belongs to conversation conv-1's editor and is not offered here", result.content

    unbound = subject.for(row("t2", conversation: "conv-9"))
    assert_same @zero, unbound.env
    assert unbound.toolset.fetch("mcp__fx__lookup").handler.call({}, context(unbound.env)).is_error, "no record: not the owner"
    standalone = subject.for(row("t3", conversation: nil))
    assert standalone.toolset.fetch("mcp__fx__lookup").handler.call({}, context(standalone.env)).is_error, "no conversation: not the owner"

    assert_raises(KeyError) { other.toolset.fetch("mcp__fx__nobody") }
    assert_raises(KeyError) { subject.zero.toolset.fetch("mcp__fx__lookup") }
  end

  def test_a_toolsets_without_extras_and_a_fixed_placement_hold_none_and_raise_as_before
    plain = toolsets({ "conv-1" => binding(@other) })
    assert_nil plain.extras
    assert_raises(KeyError) { plain.for(row("t1")).toolset.fetch("mcp__fx__lookup") }
    assert_equal @registry.names.sort, plain.names.sort

    fixed = Toolsets.fixed(env: @zero)
    assert_raises(KeyError) { fixed.for(row("t1")).toolset.fetch("mcp__fx__lookup") }
    refute_respond_to fixed, :extras
  end
end
