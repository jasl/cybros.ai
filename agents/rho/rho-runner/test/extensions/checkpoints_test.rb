require "test_helper"
require "delegate"

# THE CHECKPOINTS EXTENSION'S HOOK: a module on host state — registers only where the
# host has a store — whose `tool_call` hook captures the root BEFORE the first
# write-kind call of a loop, by the ANNOUNCED profile, once per loop, the extension's
# own tools exempt by name, and whose `tool_result` hook rides the key on the first
# write-kind result that completes. Every case runs a REAL store against a throwaway
# root; the skips are stubbed on the store (the timeout's own machinery is the store
# test's, M-mf6).
class CheckpointsExtensionTest < Minitest::Test
  Extensions = Rho::Runner::Extensions
  Checkpoints = Rho::Runner::Extensions::Checkpoints
  Store = Rho::Runner::Checkpoints::Store
  Skip = Rho::Runner::Checkpoints::Skip
  Context = Rho::Runner::ExecutionContext
  Result = Rho::Runner::Result

  # The harness's host duck: the store as a VALUE (`main.rb`); rho's
  # daemon hands a callable, which `test_a_callable_member` covers.
  Host = Data.define(:checkpoints, :processes)

  # The store with ONE verb scripted: `capture` answers the scripted value
  # (or raises it) once, then the real store's; `prune` counts. The
  # extension resolves its member per call, so a callable handing this in
  # place of the store is exactly the daemon's shape.
  class Scripted < SimpleDelegator
    attr_reader :pruned

    def initialize(store)
      super
      @script = []
      @pruned = 0
    end

    def next_capture(value) = @script << value

    def capture(**)
      return super if @script.empty?

      value = @script.shift
      value.is_a?(Exception) || value.is_a?(Class) ? raise(value) : value
    end

    def prune(**)
      @pruned += 1
      0
    end
  end

  class Log
    attr_reader :events

    def initialize = @events = []

    %i[debug info warn error].each do |level|
      define_method(level) { |event, **fields| @events << [event.to_s, fields] }
    end

    def named(event) = @events.select { |name, _| name == event }.map(&:last)
  end

  def setup
    @tmp = File.realpath(Dir.mktmpdir("rho-checkpoints-ext"))
    @root = File.join(@tmp, "root")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "lib", "a.rb"), "one")
    @log = Log.new
    @store = Store.open(dir: File.join(@tmp, "checkpoints"), root: @root, log: @log)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # The registry with the REAL coding set beside the extension, over a
  # host handing `member` — a Store, a callable, or nil.
  def load(member = @store)
    loaded = Extensions::Loader.call(
      builtin: [Extensions::Coding, Checkpoints], log: @log,
      api_options: { host: Host.new(checkpoints: member, processes: nil) }
    )
    assert_predicate loaded, :ok?, loaded.failures.inspect
    loaded
  end

  def env = Rho::Runner::ToolEnv.new(root: @root, artifacts_dir: File.join(@tmp, "artifacts"), checkpoints: @store)

  def context(run_public_id) = Context.new(run_public_id: run_public_id, task_key: "r1t0")

  # A call as the run makes it: the chain under the row's context, then
  # the result chain — answering `[gated, result]`.
  def call(registry, run_public_id, name, arguments, result: Result.ok("done"))
    toolset = registry.toolset(env: env)
    tool = toolset.fetch(name)
    hooks = registry.hooks
    Context.with(context(run_public_id)) do
      gated = hooks.before_call(name, arguments, tool)
      [gated, hooks.after_result(name, result, tool)]
    end
  end

  # ---- registration ----

  def test_registers_nothing_without_a_store_and_the_two_tools_and_the_hooks_with_one
    without = load(nil).registry
    refute_includes without.names, "checkpoint_restore"
    refute_includes without.names, "checkpoints"
    refute without.hooks.any?(:tool_call), "no store: no hook"
    refute without.hooks.any?(:tool_result)

    hostless = Extensions::Loader.call(builtin: [Checkpoints])
    assert_predicate hostless, :ok?
    assert_empty hostless.registry.names, "a standalone runner has nowhere to keep a pre-image"

    loaded = load
    assert_equal %w[checkpoint_restore checkpoints], (loaded.registry.names - Extensions::Coding::TOOLS.map { |k| k::NAME }).sort
    assert_equal ["rho.checkpoints"], loaded.registry.hooks.names(:tool_call)
    assert_equal ["rho.checkpoints"], loaded.registry.hooks.names(:tool_result)
    assert_equal [:startup], loaded.committed.find { |api| api.extension_name == "rho.checkpoints" }.lifecycle.map(&:event)
  end

  def test_a_callable_member_registers_and_is_dereferenced_per_call
    asked = 0
    registry = load(-> { asked += 1; @store }).registry
    assert_includes registry.names, "checkpoint_restore"

    call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "two" })

    assert_equal 1, asked, "the store of the moment is asked when the capture runs, not at registration"
    assert_equal ["al-1"], @store.records.map(&:run_public_id)
  end

  # ---- the capture ----

  def test_a_read_never_captures_and_the_first_write_captures_once_per_loop_and_rides_the_key_once
    registry = load.registry

    gated, result = call(registry, "al-1", "read", { "path" => "lib/a.rb" })
    assert_equal({ "path" => "lib/a.rb" }, gated, "no opinion")
    assert_nil result.metadata
    assert_empty @store.records

    _gated, first = call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "two" })
    record = @store.records(run_public_id: "al-1").first
    refute_nil record
    assert_equal({ "checkpoint" => { "hash" => record.hash, "store" => @store.id } }, first.metadata)
    refute first.metadata.fetch("checkpoint").key?("runner"), "no runner in the key (K-s1)"
    assert_equal 1, @log.named("checkpoint_captured").length

    File.write(File.join(@root, "lib", "a.rb"), "two")
    _gated, second = call(registry, "al-1", "edit", { "path" => "lib/a.rb", "edits" => [] })
    assert_nil second.metadata, "the second write of a loop rides nothing"
    assert_equal 1, @store.records.length, "one capture per loop"
    assert_equal 1, @log.named("checkpoint_captured").length

    _gated, other = call(registry, "al-2", "bash", { "command" => "true" })
    assert_equal @store.records(run_public_id: "al-2").first.hash, other.metadata.dig("checkpoint", "hash"), "bash counts; a new loop captures"
    assert_equal %w[al-1 al-2], @store.records.map(&:run_public_id)
  end

  # ONE CAPTURE PER WRITE-KIND CALL, the extension's own tools exempt by
  # name: `checkpoint_restore` captures its undo itself; the
  # `checkpoints` read is a read.
  def test_the_extensions_own_tools_are_exempt_by_name
    registry = load.registry

    call(registry, "al-1", "checkpoints", {})
    _gated, result = call(registry, "al-1", "checkpoint_restore", { "checkpoint" => "0000" })

    assert_empty @store.records, "neither name captured"
    assert_nil result.metadata
  end

  # THE STORE IS THE CONTEXT'S PLACEMENT'S: a conversation bound to another root runs its
  # tools under an env whose `checkpoints` is THAT root's store, and the capture hook
  # reads it off the context — never the daemon's one default store — so the
  # conversation's own tree is what gets captured. A context with no placement (a call
  # outside a run, the harness) falls to the member.
  def test_the_capture_reads_the_contexts_placement_store_and_captures_that_root
    bound_root = File.join(@tmp, "bound")
    FileUtils.mkdir_p(File.join(bound_root, "src"))
    File.write(File.join(bound_root, "src", "b.rb"), "bound")
    bound_store = Store.open(dir: File.join(@tmp, "checkpoints"), root: bound_root, log: @log)
    asked = 0
    registry = load(-> { asked += 1; @store }).registry
    bound_env = Rho::Runner::ToolEnv.new(root: bound_root, artifacts_dir: File.join(@tmp, "artifacts"),
      checkpoints: bound_store)
    toolset = registry.toolset(env: bound_env)
    hooks = registry.hooks

    result = Context.with(Context.new(run_public_id: "al-1", task_key: "r1t0", tool_env: bound_env)) do
      hooks.before_call("write", { "path" => "src/b.rb", "content" => "x" }, toolset.fetch("write"))
      hooks.after_result("write", Result.ok("done"), toolset.fetch("write"))
    end

    record = bound_store.records(run_public_id: "al-1").first
    refute_nil record, "the bound root's store captured"
    assert_equal bound_root, record.root
    assert_empty @store.records, "the default root's store saw nothing"
    assert_equal 0, asked, "the member was never asked: the context's placement answered"
    assert_equal({ "checkpoint" => { "hash" => record.hash, "store" => bound_store.id } }, result.metadata)
    assert_equal %w[hash store], result.metadata.fetch("checkpoint").keys,
      "`src/b.rb` is INSIDE the bound root: neither mark (the targets are judged against the placement's root)"
  end

  # THE RUNNER TOOL THE HOST RELAYS A BINDING WITH:
  # `environment_bind` is rho's, an honest write-kind runner-state write,
  # and rho-runner cannot see rho's constant — so its NAME is a string
  # here, beside the extension's own two, or every call_tool would snapshot
  # the runner's default root.
  def test_the_relayed_environment_bind_is_exempt_by_name
    assert_includes Checkpoints::EXEMPT, "environment_bind"
    assert_equal "environment_bind", Checkpoints::ENVIRONMENT_BIND
    assert_equal %w[checkpoint_restore checkpoints environment_bind], Checkpoints::EXEMPT.sort

    bind = Rho::Runner::Toolset::Tool.new(name: "environment_bind", description: "x", parameters: { "type" => "object" },
      handler: ->(_a, _c) { nil },
      effect_profile: { "kind" => "write", "destructive" => false, "effect_scope" => "closed",
                        "idempotency" => "idempotent", "reconciliation" => "none" })
    refute Checkpoints.captures?("environment_bind", bind), "write-kind, and still never captured"
  end

  # THE MARKS: a `write` whose path lies outside the
  # root still captures the root and the key says `outside`; a target the
  # excludes ignore is named in `ignored` and is not in the tree.
  def test_an_outside_root_write_marks_outside_and_an_ignored_target_marks_ignored
    registry = load.registry
    outside = File.join(@tmp, "elsewhere.txt")

    _gated, away = call(registry, "al-1", "write", { "path" => outside, "content" => "x" })
    record = @store.records(run_public_id: "al-1").first
    assert_equal [outside], record.outside
    assert_equal({ "hash" => record.hash, "store" => @store.id, "outside" => [outside] }, away.metadata.fetch("checkpoint"))

    File.write(File.join(@root, ".gitignore"), ".env\n")
    _gated, secret = call(registry, "al-2", "write", { "path" => ".env", "content" => "KEY=1" })
    key = secret.metadata.fetch("checkpoint")
    assert_equal [".env"], key.fetch("ignored")
    refute key.key?("outside")
    assert_equal [".env"], @store.records(run_public_id: "al-2").first.ignored
    tree = IO.popen({ "GIT_DIR" => @store.path, "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" },
      ["git", "ls-tree", "-r", "--name-only", key.fetch("hash")], &:read).lines(chomp: true)
    refute_includes tree, ".env", "no secret enters the store"
    assert_includes tree, ".gitignore"

    _gated, relative = call(registry, "al-3", "edit", { "path" => "lib/a.rb", "edits" => [] })
    assert_equal %w[hash store], relative.metadata.fetch("checkpoint").keys, "inside and not ignored: neither mark"
  end

  # THE TWO FLAGS: a transient skip rides NO key and is retried on
  # the loop's next write-kind call — its record then rides; a size cap is
  # final: its `skipped` key rides and the loop is closed.
  def test_a_transient_skip_is_retried_and_rides_nothing_and_a_final_skip_rides_skipped_and_closes
    scripted = Scripted.new(@store)
    registry = load(-> { scripted }).registry

    scripted.next_capture(Skip.new(reason: "timeout"))
    _gated, first = call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "two" })
    assert_nil first.metadata, "a transient skip rides nothing: the reader asks the store"
    assert_empty @store.records

    _gated, second = call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "three" })
    assert_equal @store.records(run_public_id: "al-1").first.hash, second.metadata.dig("checkpoint", "hash"), "the retry's record rides"

    scripted.next_capture(Skip.new(reason: "tree_too_large", bytes: 999, files: 3))
    _gated, capped = call(registry, "al-2", "write", { "path" => "lib/a.rb", "content" => "x" })
    assert_equal({ "checkpoint" => { "skipped" => "tree_too_large", "bytes" => 999, "files" => 3 } }, capped.metadata)
    _gated, after = call(registry, "al-2", "write", { "path" => "lib/a.rb", "content" => "y" })
    assert_nil after.metadata
    assert_nil @store.records(run_public_id: "al-2").first, "a final skip closes the run_public_id: no retry"
  end

  # THE HOOK NEVER RAISES AND NEVER VETOES: a store that raises costs the
  # capture (logged `checkpoint_skipped`), never the call — and the key
  # rides the NEXT write-kind result once a capture stands. A task's
  # cancellation alone passes through.
  def test_a_raising_store_is_no_veto_and_no_key_and_a_cancellation_passes_through
    scripted = Scripted.new(@store)
    registry = load(-> { scripted }).registry

    scripted.next_capture(RuntimeError.new("git exploded"))
    gated, result = call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "two" })
    assert_equal({ "path" => "lib/a.rb", "content" => "two" }, gated, "no veto")
    assert_nil result.metadata
    skipped = @log.named("checkpoint_skipped")
    assert_equal 1, skipped.length
    assert_equal "hook_failed", skipped.first.fetch(:reason)
    assert_equal "al-1", skipped.first.fetch(:run_public_id)

    _gated, later = call(registry, "al-1", "write", { "path" => "lib/a.rb", "content" => "three" })
    assert_equal @store.records(run_public_id: "al-1").first.hash, later.metadata.dig("checkpoint", "hash")

    scripted.next_capture(Context::Cancelled.new("execution deadline exceeded", reason: :deadline))
    assert_raises(Context::Cancelled) { call(registry, "al-9", "write", { "path" => "lib/a.rb", "content" => "z" }) }
  end

  # A CALL OUTSIDE A TASK — no context, no loop — captures nothing: there
  # is no row to correlate a key to.
  def test_no_context_captures_nothing
    registry = load.registry
    toolset = registry.toolset(env: env)
    hooks = registry.hooks

    assert_nil Context.current
    hooks.before_call("write", { "path" => "lib/a.rb", "content" => "x" }, toolset.fetch("write"))
    result = hooks.after_result("write", Result.ok("done"), toolset.fetch("write"))

    assert_empty @store.records
    assert_nil result.metadata
  end

  # A RUNNER RESTART forgets the flags; the ref is create-only, so the
  # store answers the loop's EXISTING record and the hook correlates it
  # rather than overwriting the first tree.
  def test_a_forgotten_loop_correlates_the_stores_existing_record
    first = load.registry
    _gated, before = call(first, "al-1", "write", { "path" => "lib/a.rb", "content" => "two" })
    File.write(File.join(@root, "lib", "a.rb"), "two")

    restarted = load.registry
    _gated, after = call(restarted, "al-1", "write", { "path" => "lib/a.rb", "content" => "three" })

    assert_equal before.metadata, after.metadata, "the record, not a new tree"
    assert_equal 1, @store.records.length
  end

  # `:startup` prunes the store, through the member of the moment.
  def test_startup_prunes_the_store
    scripted = Scripted.new(@store)
    loaded = load(-> { scripted })
    hook = loaded.committed.find { |api| api.extension_name == "rho.checkpoints" }.lifecycle.first

    hook.handler.call

    assert_equal 1, scripted.pruned
  end

  # The profile as ANNOUNCED decides: a tool built by hand with no
  # profile, or a read-kind one, is never a write; a hand-built write-kind
  # profile is — whatever the name.
  def test_captures_keys_off_the_announced_profile_and_the_exempt_names
    write = Rho::Runner::Toolset::Tool.new(name: "mcp_thing", description: "x", parameters: { "type" => "object" },
      handler: ->(_a, _c) { nil }, effect_profile: Rho::Runner::Tools::Write::EFFECT_PROFILE)
    read = write.with(name: "other", effect_profile: Rho::Runner::Tools::Read::EFFECT_PROFILE)
    bare = write.with(name: "echo", effect_profile: nil)

    assert Checkpoints.captures?("mcp_thing", write)
    refute Checkpoints.captures?("other", read)
    refute Checkpoints.captures?("echo", bare)
    refute Checkpoints.captures?("checkpoint_restore", write.with(name: "checkpoint_restore"))
    refute Checkpoints.captures?("checkpoints", write.with(name: "checkpoints"))
    assert_equal [[], ["lib/a.rb"]], Checkpoints.targets({ "path" => "lib/a.rb" }, @root)
    assert_equal [[File.join(@tmp, "x")], []], Checkpoints.targets({ "path" => File.join(@tmp, "x") }, @root)
    assert_equal [[], []], Checkpoints.targets({ "command" => "ls" }, @root)
    assert_equal [[], []], Checkpoints.targets({ "path" => @root }, @root), "the root itself is neither"
  end
end
