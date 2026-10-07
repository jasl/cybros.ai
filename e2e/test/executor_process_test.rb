require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "support/executor_process/echo_tools"
require "support/executor_process/memory_tools"
require "support/executor_process/main"
require "support/executor_process"

# THE HARNESS EXECUTOR'S OWN CONTRACT, in-process: what its script parses
# and what its echo tools announce — the shapes the handoff journey reads
# back through discovery and through a remote lead. A journey proves the
# process; this pins the two facts the journey would otherwise diagnose at
# the end of a fifteen-minute run.
class ExecutorProcessTest < Minitest::Test
  # THE ANNOUNCED ENVIRONMENT: a runner elsewhere says where its relative paths resolve, in the
  # sentence shape rho's own runner announces (`Coding::Report`), so a lead rendered from the
  # snapshot names the root and nothing else.
  def test_the_echo_tools_announce_the_root_they_were_given
    environment = E2E::EchoTools.environment("/srv/h")
    assert_equal "/srv/h", environment.fetch("root")
    assert_equal [{ "extension" => "e2e.echo", "text" => "Relative paths resolve against /srv/h." }],
      environment.fetch("fragments")
    assert_equal %w[root fragments], environment.keys
  end

  def test_the_script_parses_an_environment_root_and_defaults_to_none
    options = E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test --environment-root /srv/h])
    assert_equal "/srv/h", options.fetch(:environment_root)
    assert_nil E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test])[:environment_root]
  end

  # THE WORLD FLAGS: a world serves the coding set whole (no `--tools`), a store needs a world, and
  # a plain parse is what it was.
  def test_the_script_parses_a_world_and_its_store_and_refuses_the_half_shapes
    options = E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test --world /srv/w --checkpoints /srv/c --artifacts /srv/a])
    assert_equal "/srv/w", options.fetch(:world)
    assert_equal "/srv/c", options.fetch(:checkpoints)
    assert_equal "/srv/a", options.fetch(:artifacts)
    assert_nil options.fetch(:tools), "no harness set under a world"
    alone = E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test --world /srv/w])
    assert_nil alone.fetch(:checkpoints), "a world without a store: the coding set, no capture"
    assert_raises(ArgumentError) { E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test --checkpoints /srv/c]) }
    assert_raises(ArgumentError) { E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test --world /srv/w --tools read]) }
    assert_raises(ArgumentError) { E2E::ExecutorProcess.new(base_url: "x", home: "/h", credential: "c", checkpoints: "/c") }
    plain = E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test])
    assert_nil plain.fetch(:world)
    assert_equal E2E::EchoTools.names, plain.fetch(:tools)
  end

  # THE WORLD'S ASSEMBLY: under `--world --checkpoints` the process opens the store at DIR/<digest>,
  # serves rho-runner's REAL coding set whole plus the two hidden names, and announces through
  # `Registry#announcement` — the two hidden names name and profile alone; under `--world` alone the
  # same set with no store and neither name; and a lane that passes no `--world` announces through
  # the SAME renderer: the names asked for and only those, sorted, each entry's park the class's own
  # `TIMEOUT_MS` — the number the served `Tool` carries.
  def test_a_world_assembles_the_real_coding_set_and_the_store_and_the_other_lanes_announce_through_the_one_renderer
    Dir.mktmpdir("e2e-world") do |tmp|
      world = File.join(tmp, "project")
      FileUtils.mkdir_p(File.join(world, "lib"))
      File.write(File.join(world, "lib", "a.rb"), "one")
      checkpoints = File.join(tmp, "checkpoints")
      coding = Rho::Runner::Extensions::Coding::TOOLS.map { |klass| klass::NAME }.sort

      with_store = E2E::ExecutorMain.assemble(
        { world: world, checkpoints: checkpoints, artifacts: File.join(tmp, "artifacts") }, nil
      )
      assert_equal (coding + %w[checkpoints checkpoint_restore]).sort, with_store.toolset.names.sort
      assert_equal File.join(File.realpath(tmp), "checkpoints", Rho::Runner::Checkpoints::Store.digest(world)), with_store.store.path,
        "the store dir carries the root's real spelling (a /var tmp), before it exists"
      assert_equal File.realpath(world), with_store.store.root
      assert_equal File.realpath(world), with_store.world
      names = with_store.announcement.map { |entry| entry.fetch("name") }
      assert_equal names.sort, names, "sorted by name"
      assert_equal (coding + %w[checkpoints checkpoint_restore]).sort, names
      hidden = with_store.announcement.select { |e| %w[checkpoints checkpoint_restore files_bytes].include?(e.fetch("name")) }
      hidden.each { |e| assert_equal (%w[name effect_profile] + (e.fetch("name") == "checkpoint_restore" ? ["timeout_ms"] : [])).sort, e.keys.sort, e.fetch("name") }
      assert_equal File.realpath(world), with_store.environment.fetch("root")
      assert_equal ["rho.coding"], with_store.environment.fetch("fragments").map { |f| f.fetch("extension") }
      assert_equal [], with_store.documents
      # The capture hook rides the assembly: the runner is built with the registry's chain, so the
      # first write-kind call captures.
      assert_equal ["rho.checkpoints"], with_store.hooks.names(:tool_call)
      assert_equal ["rho.checkpoints"], with_store.hooks.names(:tool_result)
      # THE ONE PLACEMENT: the process serves no per-conversation binding — `Toolsets.fixed` over
      # the world's env and toolset, so every claim lands on the world's root and the capture hook
      # reads the world's store off the context's placement.
      assert_equal File.realpath(world), with_store.env.root
      assert_same with_store.store, with_store.env.checkpoints
      placement = E2E::ExecutorMain.toolsets(with_store).for(nil)
      assert_same with_store.env, placement.env
      assert_same with_store.toolset, placement.toolset
      assert_nil placement.binding

      alone = E2E::ExecutorMain.assemble({ world: world, artifacts: File.join(tmp, "artifacts") }, nil)
      assert_nil alone.store
      assert_equal coding, alone.toolset.names.sort, "a world without a store serves the coding set and neither hidden name"
      refute_includes alone.announcement.map { |e| e.fetch("name") }, "checkpoint_restore"
      refute alone.hooks.any?(:tool_call), "no store: no capture hook"

      names = %w[read memory_read memory_write]
      harness = E2E::ExecutorMain.assemble({ tools: names, environment_root: "/srv/h" }, nil)
      assert_equal names, harness.toolset.names
      assert_equal names.sort, harness.announcement.map { |entry| entry.fetch("name") },
        "the names asked for and only those, in the renderer's order"
      registry = Rho::Runner::Extensions::Loader.call(builtin: E2E::HarnessTools::MODULES).registry
      assert_equal registry.announcement.select { |entry| names.include?(entry.fetch("name")) }, harness.announcement,
        "the lanes that pass no --world announce the registry's own rendering, narrowed to their names"
      harness.announcement.each do |entry|
        tool = harness.toolset.fetch(entry.fetch("name"))
        assert_equal E2E::EchoTools::TIMEOUT_MS, tool.timeout_ms, "the served Tool carries the class's park: #{tool.name}"
        assert_equal tool.timeout_ms, entry.fetch("timeout_ms"), "and the announced park IS it: #{tool.name}"
        assert_equal tool.effect_profile, entry.fetch("effect_profile"), tool.name
      end
      assert_equal "/srv/h", harness.environment.fetch("root")
      assert_nil harness.store
      assert_nil harness.world
      assert_nil harness.hooks, "the harness set carries no chain: the runner's empty host"
      assert_nil harness.env, "the harness set binds no root: its tools take none"
      narrowed = E2E::ExecutorMain.toolsets(harness).for(nil)
      assert_same harness.toolset, narrowed.toolset
      assert_nil narrowed.env
      assert_equal names, E2E::ExecutorMain.toolsets(harness).names
    end
  end

  # A nil root announces NO environment: the kernel stores `{}` for the
  # provider journeys, whose leads name no root.
  def test_no_root_announces_no_environment
    assert_nil E2E::ExecutorMain.environment_for(nil)
    assert_equal "/srv/h", E2E::ExecutorMain.environment_for("/srv/h").fetch("root")
  end

  # THE SAMPLE PROVIDER'S CONTRACT: the six kernel wire names, each announced — through the
  # registry's renderer over the memory module alone — with the KERNEL's own effect profile: the
  # row's frozen profile is what the sweep reads at expiry, so a provider that mirrored the kernel's
  # verbs with a different profile would settle them differently. The script's default stays the
  # echo set; the memory set is asked for by name, and `toolset_for` resolves both modules.
  MEMORY_NAMES = %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write].freeze

  def test_the_memory_tools_announce_the_kernel_names_with_the_kernel_profiles
    assert_equal MEMORY_NAMES, E2E::MemoryTools.names.sort
    registry = Rho::Runner::Extensions::Loader.call(builtin: [E2E::MemoryTools]).registry
    announced = registry.announcement.to_h { |entry| [entry.fetch("name"), entry] }
    assert_equal MEMORY_NAMES, announced.keys
    %w[memory_read memory_ls memory_grep].each do |name|
      assert_equal E2E::EchoTools::READ_ONLY, announced.fetch(name).fetch("effect_profile"), name
    end
    %w[memory_write memory_delete].each do |name|
      assert_equal E2E::MemoryTools::MEMORY_WRITE, announced.fetch(name).fetch("effect_profile"), name
    end
    assert_equal E2E::MemoryTools::MEMORY_WRITE.merge("idempotency" => "none"),
      announced.fetch("memory_edit").fetch("effect_profile")
    announced.each_value do |entry|
      assert_equal E2E::MemoryTools::TIMEOUT_MS, entry.fetch("timeout_ms"), "the verb class's own park"
      assert_equal "object", entry.fetch("input_schema").fetch("type")
      assert_includes entry.fetch("description"), "keyed by the row's scope"
    end
    assert_equal ["path"], announced.fetch("memory_read").fetch("input_schema").fetch("required")
    assert_equal %w[path content], announced.fetch("memory_write").fetch("input_schema").fetch("required")
    assert_equal %w[path old_text new_text], announced.fetch("memory_edit").fetch("input_schema").fetch("required")
    assert_equal ["pattern"], announced.fetch("memory_grep").fetch("input_schema").fetch("required")
  end

  def test_the_script_defaults_to_the_echo_set_and_loads_both_modules_by_name
    assert_equal E2E::EchoTools.names, E2E::ExecutorMain.parse(%w[--nexus-url http://nexus.test]).fetch(:tools)
    names = %w[read memory_read memory_write]
    toolset = E2E::ExecutorMain.toolset_for(names, nil)
    assert_equal names, toolset.names
    announcement = E2E::ExecutorMain.assemble({ tools: names }, nil).announcement
    assert_equal names.sort, announcement.map { |entry| entry.fetch("name") }
    echo_alone = Rho::Runner::Extensions::Loader.call(builtin: [E2E::EchoTools]).registry.announcement
    assert_equal echo_alone.select { |entry| entry.fetch("name") == "read" }, [announcement.last],
      "the echo module's own class renders the same entry wherever it is loaded"
    error = assert_raises(ArgumentError) { E2E::ExecutorMain.toolset_for(%w[read memory_bogus], nil) }
    assert_includes error.message, "memory_bogus"
  end

  # THE STORE IS KEYED BY THE ROW'S SCOPE, never by `tool_input` alone: two workspaces'
  # `workspace/notes.md` are two documents, a `user/` document belongs to the stamped person, and a
  # row without the kernel's stamp is refused rather than guessed. The sentences are the kernel's
  # (`AgentRuns::Memory::Run`), so a mock transcript reads the same whichever authority answered.
  def test_the_memory_store_is_keyed_by_the_scope_stamp_and_speaks_the_kernels_sentences
    E2E::MemoryTools::Store.clear!
    a = memory_scope(workspace: "ws-a", user: "hu-a")
    b = memory_scope(workspace: "ws-b", conversation: "cv-b", user: "hu-b")

    assert_equal "Wrote workspace/notes.md (5 bytes).", under(a) { call(:memory_write, "path" => "workspace/notes.md", "content" => "one-a") }
    assert_equal "Wrote workspace/notes.md (5 bytes).", under(b) { call(:memory_write, "path" => "workspace/notes.md", "content" => "one-b") }
    assert_equal "Wrote user/notes.md (6 bytes).", under(a) { call(:memory_write, "path" => "user/notes.md", "content" => "user-a") }
    assert_equal "one-a", under(a) { call(:memory_read, "path" => "workspace/notes.md") }
    assert_equal "one-b", under(b) { call(:memory_read, "path" => "workspace/notes.md") }, "two workspaces, two documents"

    missing = under(b) { result(:memory_read, "path" => "user/notes.md") }
    assert missing.is_error
    assert_equal "memory_not_found: notes.md", missing.content, "A's user/ is not B's"

    listed = under(a) { call(:memory_ls, {}) }
    assert_equal 2, listed.lines.length, listed
    assert_match(%r{\Auser/notes\.md  6 bytes  \d{4}-\d{2}-\d{2}T}, listed.lines.first, "path order, the kernel's line shape")
    assert_match(%r{^workspace/notes\.md  5 bytes  }, listed)
    assert_equal "No memory documents.", under(b) { call(:memory_ls, "path" => "user/") }
    assert_equal "workspace/notes.md:1: one-b", under(b) { call(:memory_grep, "pattern" => "ONE", "ignore_case" => true) }
    assert_equal "No matches found.", under(a) { call(:memory_grep, "pattern" => "zzz") }

    assert_equal "Edited workspace/notes.md.", under(a) { call(:memory_edit, "path" => "workspace/notes.md", "old_text" => "one", "new_text" => "two") }
    assert_equal "two-a", under(a) { call(:memory_read, "path" => "workspace/notes.md") }
    ambiguous = under(a) { result(:memory_edit, "path" => "workspace/notes.md", "old_text" => "-", "new_text" => "x") }
    assert_equal "memory_edit_not_found: zz", under(a) { result(:memory_edit, "path" => "workspace/notes.md", "old_text" => "zz", "new_text" => "x") }.content
    refute ambiguous.is_error, "one hyphen, one occurrence"
    assert_equal "Deleted user/notes.md.", under(a) { call(:memory_delete, "path" => "user/notes.md") }
    assert_equal "memory_not_found: notes.md", under(a) { result(:memory_delete, "path" => "user/notes.md") }.content

    # The refusals are data the model reads, in the kernel's spellings.
    assert_equal "memory_scope_unavailable: conversation/x.md",
      under(a) { result(:memory_read, "path" => "conversation/x.md") }.content, "a standalone row has no conversation"
    assert_equal "memory_path_invalid: notes.md", under(a) { result(:memory_read, "path" => "notes.md") }.content
    assert_equal "memory_scope_unavailable: attic/notes.md", under(a) { result(:memory_write, "path" => "attic/notes.md", "content" => "x") }.content
    unstamped = Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { result(:memory_read, "path" => "workspace/notes.md") }
    assert unstamped.is_error
    assert_equal "memory_scope_unavailable: no scope on the row", unstamped.content, "never guessed from tool_input"

    # A long read is sliced the kernel's way.
    under(a) { call(:memory_write, "path" => "workspace/long.md", "content" => (1..5).map { |n| "line #{n}" }.join("\n")) }
    assert_equal "line 2\nline 3\n\n[Showing 2 of 4 lines. Continue with offset=4.]",
      under(a) { call(:memory_read, "path" => "workspace/long.md", "offset" => 2, "limit" => 2) }
  ensure
    E2E::MemoryTools::Store.clear!
  end

  def test_memory_binding_names_share_their_anchor_and_read_only_or_omitted_roots_cannot_author
    E2E::MemoryTools::Store.clear!
    source = memory_scope(conversation: "cv-source")
    under(source) { call(:memory_write, "path" => "conversation/notes.md", "content" => "source") }
    named = { "bindings" => [
      memory_binding("shared", "cv-source", scope: "conversation", access: "read"),
      memory_binding("working", "cv-source", scope: "conversation"),
    ] }

    assert_equal "source", under(named) { call(:memory_read, "path" => "shared/notes.md") }
    listed = under(named) { call(:memory_ls, {}) }
    assert_equal %w[shared/notes.md working/notes.md], listed.lines.map { |line| line.split("  ").first }
    assert_equal "working/notes.md:1: source", under(named) { call(:memory_grep, "path" => "working/no", "pattern" => "source") }
    assert_equal "memory_scope_unavailable: conversation/notes.md",
      under(named) { result(:memory_read, "path" => "conversation/notes.md") }.content

    {
      memory_write: { "content" => "changed" },
      memory_edit: { "old_text" => "source", "new_text" => "changed" },
      memory_delete: {},
    }.each do |verb, args|
      answer = under(named) { result(verb, args.merge("path" => "shared/notes.md")) }
      assert answer.is_error
      assert_equal "memory_read_only: shared/notes.md", answer.content
    end
    assert_equal "source", under(source) { call(:memory_read, "path" => "conversation/notes.md") }

    assert_equal "Edited working/notes.md.",
      under(named) { call(:memory_edit, "path" => "working/notes.md", "old_text" => "source", "new_text" => "changed") }
    assert_equal "changed", under(named) { call(:memory_read, "path" => "shared/notes.md") }, "aliases use one physical document"
    assert_equal "Wrote working/new.md (3 bytes).", under(named) { call(:memory_write, "path" => "working/new.md", "content" => "new") }
    assert_equal "Deleted working/new.md.", under(named) { call(:memory_delete, "path" => "working/new.md") }

    assert_equal "No memory documents.", under(memory_scope) { call(:memory_ls, {}) }
    assert_equal "No matches found.", under(memory_scope) { call(:memory_grep, "pattern" => "changed") }
    assert_equal "memory_scope_unavailable: conversation/notes.md",
      under(memory_scope) { result(:memory_read, "path" => "conversation/notes.md") }.content
  ensure
    E2E::MemoryTools::Store.clear!
  end

  private

    def memory_scope(**roots)
      { "bindings" => roots.map { |name, id| memory_binding(name.to_s, id) } }
    end

    def memory_binding(name, id, scope: name, access: "read_write")
      { "name" => name, "scope" => scope, "access" => access, "#{scope}_public_id" => id }
    end

    def under(scope, &block)
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(scope: scope.freeze), &block)
    end

    def result(name, args)
      klass = E2E::MemoryTools::TOOLS.find { |candidate| candidate::NAME == name.to_s }
      refute_nil klass, name
      klass.new(env: nil).call(args)
    end

    def call(name, args)
      answer = result(name, args)
      refute answer.is_error, "#{name} refused: #{answer.content}"
      answer.content
    end
end
