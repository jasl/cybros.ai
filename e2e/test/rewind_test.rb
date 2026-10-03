require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/executor_process"
require "support/fixture_project"
require "support/gallery/shapes"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# REWIND / CHECKPOINT, END TO END: the SDK's composition and rho's two verbs over a REAL world. An
# AGENT-mode rho daemon names a RUNNER — the harness `ExecutorProcess` started with `--world ROOT
# --checkpoints DIR`, serving rho-runner's whole coding set bound to a FixtureProject and opening a
# shadow git store beside it — and drives, through `exe/rho`, the capture on the first write, the
# reserved key riding the result, the world fact on the reply variant, the restore through a request
# loop with EVERY fixture byte pinned to the pre-image, the undo, the regenerate witness (a
# deterministic mock `edit` that only succeeds on a restored tree), `--keep-world`, an active-turn
# refusal, an outside-root write, a runner that keeps no store, and model-invisibility. No paid
# lane: no MODEL behaviour is under test. The mock's calls are REAL writes on the root.
#
# ONE CEREMONY PER FILE, TWO GRANTS: the steward's session, the agent-mode
# daemon on its own home, and the harness runner granted user-private. The
# fixture project is written under the journey's tmp home; a byte copy of
# the pre-image is taken before the first write.
class RewindTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  RUNNER_IDENTIFIER = "cybros-e2e-rewind-runner".freeze
  RUNNER_DISPLAY_NAME = "E2E rewind runner".freeze
  POLL = 1
  AWAIT_SECONDS = 120
  PROJECT_FILES = { "README.md" => "the fixture\n", "lib/a.rb" => "one\n" }.freeze

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, :runner, :runner_home,
    :runner_root, :checkpoints_dir, :project, :runner_id, :credential, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-rewind-e2e")
      runner_home = Dir.mktmpdir("e2e-rewind-runner")
      world_home = Dir.mktmpdir("e2e-rewind-world")
      project = E2E::FixtureProject.write(world_home, "project", PROJECT_FILES)
      File.write(File.join(home, "settings.json"), JSON.generate("extensions" => ["rho/dev"], "extension_paths" => []))
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_MODE" => "agent" })
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor, runner_home: runner_home,
        runner_root: project.root, checkpoints_dir: File.join(runner_home, "checkpoints"), project: project)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      grant_runner!(base_url, actor)
      @world
    end

    # THE GRANT, then the WORLD process: a RUNNER bound to ROOT with a shadow store under DIR; the
    # transport credential reaches the child on stdin through the browser ceremony and is kept, so a
    # later arm can restart the SAME runner WITHOUT a store.
    def grant_runner!(base_url, actor)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        runner_identifier: RUNNER_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME, executor_kind: "runner"
      )
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      offer = E2E::RunnerGrant.scope_offer(actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = device.await_credentials(authorization)
      @world.credential = credentials.executor_access_token
      runner = E2E::ExecutorProcess.new(base_url: base_url, home: @world.runner_home,
        credential: @world.credential, kind: :runner, world: @world.runner_root, checkpoints: @world.checkpoints_dir)
      runner.start
      @world.runner = runner
      @world.runner_id = runner.executor_public_id
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == "adopted" ? workspace.fetch("public_id") : nil
      end
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      { "the runner process" => world.runner, "the rho daemon" => world.daemon }.each do |label, process|
        process&.stop
      rescue StandardError => error
        warn "Could not stop #{label}: #{error.class}: #{error.message}"
      end
      [world.home, world.runner_home, File.dirname(world.runner_root)].each do |dir|
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      end
    end
  end

  Minitest.after_run { RewindTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @runner = @world.runner
    @runner_id = @world.runner_id
    @root = @world.runner_root
    @workspace_public_id = @world.workspace_public_id
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @world.steward.member_token)
    assert_equal "runner", @runner.announced_kind
    assert_includes @runner.announced, "world_restore", "the world runner announces the restore"
    assert_includes @runner.announced, "checkpoints", "and the read"
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    warn_log(@runner&.log_path, "runner process log")
  rescue StandardError => error
    warn "Could not capture the rewind E2E logs: #{error.class}: #{error.message}"
  end

  # THE WHOLE JOURNEY on one world, in order: the world is expensive and
  # every step reads the residue of the last.
  def test_capture_restore_regenerate_and_the_negatives
    capture_and_correlate
    the_per_turn_diff
    rewind_restores_the_pre_image
    the_undo_brings_the_dirty_tree_back
    regenerate_restores_then_the_door
    keep_world_regenerates_on_the_world_as_it_is
    an_outside_root_write_is_marked
    an_active_turn_refuses_locally
    a_runner_without_a_store_is_no_checkpoint
    model_invisibility
  end

  private

    # STEP 1 — WRITE + CAPTURE: the first write-kind call captures the tree
    # before it; the reserved key rides that result and none other; the
    # reply variant carries the world fact; the cache equals the truth
    # across three reads.
    def capture_and_correlate
      @pre_image = @world.project.files.transform_values(&:dup)
      # Through rho every turn is a `direct_reply` (T0, loop-backed, nothing
      # before it): a rewind names the turn ABOVE which the first write
      # stands, so the opening turn writes nothing and the writes ride a
      # `say` — T1, whose loop L1 captures the pre-image.
      opened = rho_do("!mock -- hello")
      await_loop_status(opened.loop, "completed")
      assert_empty @runner.captures, "a turn that wrote nothing captured nothing"
      @first_conversation = opened.conversation
      @first_loop_id = rho_say(@first_conversation, script(["edit", edit_args("lib/a.rb", "one", "two")],
        ["bash", { "command" => "echo two-b > lib/b.rb" }]))
      completed = await_loop_status(@first_loop_id, "completed")

      captures = @runner.captures
      assert_equal 1, captures.length, "one capture for the loop: #{@runner.log_text}"
      @h1 = captures.first.fetch("hash")
      assert_equal 2, captures.first.fetch("files"), "two blobs captured before the first write"

      edit = tool_task(completed, "edit")
      bash = tool_task(completed, "bash")
      @first_turn_answers = completed.tasks.count(&:tool_call?)
      @edit_task_key = edit.key
      edit_detail = loops.agent_loop(@first_loop_id).task(edit.key)
      assert_equal @h1, edit_detail.metadata.dig("checkpoint", "hash"), "the key rides the FIRST write's result"
      refute edit_detail.metadata.fetch("checkpoint").key?("runner"), "no runner in the key"
      assert_nil loops.agent_loop(@first_loop_id).task(bash.key).metadata, "the second write carries no key"

      world = reply_variant(@first_conversation).world
      assert_predicate world, :touched?
      assert_equal @runner_id, world.runner
      assert_equal @h1, world.checkpoint_hash

      # as ONE equality across three reads.
      assert_equal @h1, relay_records(@first_loop_id).first.fetch("hash")
      assert_equal @h1, edit_detail.metadata.dig("checkpoint", "hash")

      assert_equal "two\n", read_root("lib/a.rb")
      assert_equal "two-b\n", read_root("lib/b.rb")
    end

    # STEP 2 — A SECOND TURN, and the per-turn diff with no work-tree pass.
    # THE FAKE'S SCRIPT INDEX IS THE CONVERSATION'S ANSWER COUNT (mock_llm/
    # app.rb `answers_in`: every `function_call_output` in the input, turn
    # one's included), so the second turn's script is padded by the answers
    # turn one left — its `edit` sits at the index the fake will read.
    def the_per_turn_diff
      pads = Array.new(@first_turn_answers) { ["read", { "path" => "README.md" }] }
      loop_id = rho_say(@first_conversation, script(*pads, ["edit", edit_args("lib/a.rb", "two", "three")]))
      await_loop_status(loop_id, "completed")
      @h2 = @runner.captures.find { |line| line.fetch("loop") == loop_id }&.fetch("hash")
      refute_nil @h2, "the second loop captured its own pre-image"
      paths = relay_changed(@h1, @h2).map { |row| row.fetch("path") }.sort
      assert_equal ["lib/a.rb", "lib/b.rb"], paths, "turn one's changes: H1 → H2, no work-tree pass"
    end

    # STEP 3 — REWIND at the first message: the physical first write above it
    # is L1's, so the fork point's world names H1; the restore puts EVERY
    # fixture path back to the pre-image and removes what the turn added.
    def rewind_restores_the_pre_image
      turn = opening_turn(@first_conversation)
      output = rho("rewind", @first_conversation, turn.public_id)
      child = output[/^conversation: (\S+)/, 1]
      refute_nil child, output
      assert_match(/^world:        restored #{Regexp.escape(@h1)} \(undo \S+\)$/, output, output)
      @undo_h3 = output[/undo (\S+)\)/, 1]

      assert_equal @h1, @runner.restores.last.fetch("to")

      @pre_image.each { |path, bytes| assert_equal bytes, read_root(path), "#{path} back to the pre-image" }
      refute File.exist?(File.join(@root, "lib", "b.rb")), "the file the turn added is gone"

      child_conversation = @steward_client.workspace(@workspace_public_id).conversation(child).fetch
      assert_equal turn.public_id, child_conversation.forked_from_turn_public_id
      assert_equal @runner_id, child_conversation.runner.executor_public_id

      graph = graph_of(restore_request_loop)
      assert_equal 1, E2E::Gallery.nodes_of(graph, kind: "tool_task").length, "one node: the request is the whole run"

      # The stat cache refreshed: the store's index and the work tree agree after the restore — `git
      # diff-files` is empty.
      store = @runner.announced_checkpoints
      refute_nil store, "the runner announced its store"
      dirty = IO.popen(["git", "--git-dir", store, "--work-tree", @root, "diff-files", "--name-only"], &:read)
      assert_equal "", dirty, "git diff-files is empty after the restore"
    end

    # STEP 4 — UNDO: the undo checkpoint restores the dirty tree byte for byte.
    def the_undo_brings_the_dirty_tree_back
      output, status = @daemon.cli("relay", @runner_id, "world_restore", JSON.generate("checkpoint" => @undo_h3))
      assert_predicate status, :success?, output
      assert_equal "three\n", read_root("lib/a.rb"), "the undo brought a.rb back"
      assert_equal "two-b\n", read_root("lib/b.rb"), "and the file the turn added"
    end

    # STEP 5 — REGENERATE, THE WITNESS: a fresh conversation whose tail wrote,
    # regenerated — the restore runs FIRST, then the door re-runs the edit,
    # which succeeds only because the world was restored.
    def regenerate_restores_then_the_door
      turn = rho_do(script(["edit", edit_args("lib/a.rb", "three", "four")]))
      await_loop_status(turn.loop, "completed")
      assert_equal "four\n", read_root("lib/a.rb")
      reply = reply_turn(turn.conversation)
      assert_predicate reply.active_variant.world, :touched?

      origin_hash = reply.active_variant.world.checkpoint_hash
      before = @runner.restores.length
      output = rho("regenerate", turn.conversation, reply.public_id)
      assert_match(/^world:     restored #{Regexp.escape(origin_hash)} \(undo \S+\)$/, output, output)
      assert_operator @runner.restores.length, :>, before, "the regenerate's restore ran"
      assert_equal origin_hash, @runner.restores.last.fetch("to"), "the tail's own pre-image"
      @regenerate_conversation = turn.conversation
      @regenerate_turn = reply.public_id

      # THE WITNESS: the new candidate's `edit three → four` finds `three`
      # only because the restore ran first; its first write captured the
      # SAME tree the origin did (dedup: same bytes, same hash); the deck is
      # two, the new candidate active on completion.
      candidate = candidate_loop(turn.conversation, reply.public_id, output[/^variant:\s+(\S+)/, 1])
      completed = await_loop_status(candidate, "completed")
      refute tool_task(completed, "edit").result["is_error"], "the edit found `three`: the world was restored first"
      assert_equal "four\n", read_root("lib/a.rb")
      assert_equal origin_hash, @runner.captures.find { |line| line.fetch("loop") == candidate }&.fetch("hash"),
        "the candidate's capture dedups onto the origin's tree"
      # THE SETTLE, NOT THE LOOP: the loop row completes first and the
      # converger's settle — the variant's own status and the turn's
      # active variant in ONE write (`ConversationTurnVariant#settle`) —
      # lands a moment later; a deck read between the two saw the origin
      # still active (the gate on 0d4b714e, seed 25353). The wait is on
      # the candidate variant's settled status; the pins below stand.
      deck = await("the candidate's variant never settled completed") do
        rows = variants(turn.conversation, reply.public_id)
        rows if rows.items.find { |variant| variant.agent_loop_public_id == candidate }&.status == "completed"
      end
      assert_equal 2, deck.length, "the deck of two"
      assert_equal candidate, deck.active.agent_loop_public_id, "the new candidate is active on completion"
    end

    # STEP 6 — `--keep-world`: no restore, the world left as it is.
    def keep_world_regenerates_on_the_world_as_it_is
      before = @runner.restores.length
      output = rho("regenerate", @regenerate_conversation, @regenerate_turn, "--keep-world")
      assert_match(/^world:     kept$/, output, output)
      assert_equal before, @runner.restores.length, "--keep-world restores nothing"

      # The third candidate's `edit three → four` answers `is_error` — the
      # world was left as it was (`four`) — and the loop still completes.
      candidate = candidate_loop(@regenerate_conversation, @regenerate_turn, output[/^variant:\s+(\S+)/, 1])
      completed = await_loop_status(candidate, "completed")
      assert tool_task(completed, "edit").result["is_error"], "`three` is not there: the world was left as it was"
      assert_equal "four\n", read_root("lib/a.rb"), "and stays as it was"
      assert_equal 3, variants(@regenerate_conversation, @regenerate_turn).length, "a third candidate"
    end

    # STEP 7 (vi) — an OUTSIDE-ROOT write: the capture still runs for the
    # root and the key carries the outside path; the file is untouched by a
    # later restore.
    def an_outside_root_write_is_marked
      outside = File.join(@world.home, "outside-#{SecureRandom.hex(4)}.txt")
      turn = rho_do(script(["write", { "path" => outside, "content" => "out\n" }]))
      completed = await_loop_status(turn.loop, "completed")
      write = tool_task(completed, "write")
      key = loops.agent_loop(turn.loop).task(write.key).metadata&.dig("checkpoint", "outside")
      assert_equal [outside], key, "the key names what a restore cannot reach"
    end

    # STEP 7 (iv) — an active turn: `rho rewind` refuses locally, no request
    # loop made.
    def an_active_turn_refuses_locally
      before = loops.list(order: "desc", limit: 100).items.length
      background = @daemon.cli_background("do", script(["bash", { "command" => "sleep 20" }]),
        "--model", MODEL, "--runner", @runner_id)
      conversation = await_active_conversation
      output, status = @daemon.cli("rewind", conversation, "0")
      refute_predicate status, :success?, output
      assert_match(/a turn is running/, output)
      assert_equal before + 1, loops.list(order: "desc", limit: 100).items.length,
        "the running turn's loop alone: no request loop was created for the refused rewind"
    ensure
      background&.close
      @daemon.cli("stop", conversation) if conversation
    end

    # STEP 7 (i) — the runner restarted WITHOUT `--checkpoints` on the same
    # credential: a write's variant is touched with NO checkpoint, and
    # `rho rewind` asks the store, `tool_not_served`, and prints
    # unavailable. Runs last: it leaves the runner without a store.
    def a_runner_without_a_store_is_no_checkpoint
      @runner.stop
      storeless = E2E::ExecutorProcess.new(base_url: @base_url, home: @world.runner_home,
        credential: @world.credential, kind: :runner, world: @root)
      storeless.start
      @world.runner = storeless
      @runner = storeless

      opened = rho_do("!mock -- hello")
      await_loop_status(opened.loop, "completed")
      loop_id = rho_say(opened.conversation, script(["edit", edit_args("lib/a.rb", "four", "five")]))
      await_loop_status(loop_id, "completed")
      world = reply_variant(opened.conversation).world
      assert_predicate world, :touched?
      assert_nil world.checkpoint_hash, "no store, no checkpoint on the fact"

      output = rho("rewind", opened.conversation, opening_turn(opened.conversation).public_id)
      assert_match(/^world:        unavailable: no_checkpoint$/, output, output)
    end

    # STEP 8 — MODEL-INVISIBILITY: the sealed request of the round AFTER the
    # edit carries neither the string `checkpoint` nor the tree hash.
    def model_invisibility
      # The model round AFTER the edit's (its sealed request carries the
      # edit's `function_call_output`), found by key — `rNt0` was called by
      # round `rN`, and the next model round reads its answer.
      edit_round = @edit_task_key[/\Ar(\d+)/, 1].to_i
      keys = loops.fetch(@first_loop_id).tasks.select(&:round?).map(&:key)
      after = keys.sort_by { |key| key[/\Ar(\d+)/, 1].to_i }.find { |key| key[/\Ar(\d+)/, 1].to_i > edit_round }
      refute_nil after, "no model round after the edit's #{@edit_task_key}: #{keys.inspect}"
      output, status = @daemon.cli("request", @first_loop_id, after)
      assert_predicate status, :success?, "the round after the edit is the pin:\n#{output}"

      refute_match(/checkpoint/, output, "the reserved key never reaches the model's sealed request")
      refute_match(/#{Regexp.escape(@h1)}/, output, "nor the tree hash")
    end

    # ---- helpers ----

    Turn = Struct.new(:conversation, :turn, :loop, keyword_init: true)

    def rho(*args)
      output, status = @daemon.cli(*args)
      assert_predicate status, :success?, "rho #{args.first} failed:\n#{output}"
      output
    end

    def rho_do(prompt)
      output = rho("do", prompt, "--model", MODEL, "--runner", @runner_id)
      Turn.new(conversation: output[/^conversation: (\S+)/, 1], turn: output[/^turn:\s+(\S+)/, 1],
        loop: output[/^loop:\s+(\S+)/, 1] || flunk("rho do printed no loop id:\n#{output}"))
    end

    def rho_say(conversation, prompt)
      before = reply_loop_ids(conversation)
      rho("say", conversation, prompt, "--mode", "queue")
      await("no new reply loop for #{conversation}") { (reply_loop_ids(conversation) - before).first }
    end

    def reply_loop_ids(conversation)
      loops.list(order: "desc", limit: 20).items
        .select { |row| row.turn&.conversation_public_id == conversation }.map(&:public_id)
    end

    def relay_records(loop_id) = relay_structured("checkpoints", "loop" => loop_id).fetch("records", [])
    def relay_changed(from, to) = relay_structured("checkpoints", "from" => from, "to" => to).fetch("changed", [])

    def relay_structured(tool, input)
      output, status = @daemon.cli("relay", @runner_id, tool, JSON.generate(input))
      assert_predicate status, :success?, output
      loop_id = output[/^loop:\s+(\S+)/, 1]
      loops.agent_loop(loop_id).task("relay").structured_content || {}
    end

    def restore_request_loop
      loops.list(order: "desc", limit: 20).items.map(&:public_id).find do |candidate|
        row = loops.fetch(candidate)
        row.tasks.one? && row.tasks.first.tool_name == "world_restore"
      end
    end

    def graph_of(loop_id)
      graph, status = @daemon.cli("graph", loop_id, "--json")
      assert_predicate status, :success?, graph
      JSON.parse(graph)
    end

    # The loop behind the candidate `rho regenerate` printed, off the deck.
    def candidate_loop(conversation, turn_public_id, variant_id)
      refute_nil variant_id, "rho regenerate printed no variant"
      candidate = variants(conversation, turn_public_id).items.find { |variant| variant.public_id == variant_id }
      refute_nil candidate, "the deck lacks #{variant_id}"
      candidate.agent_loop_public_id || flunk("the new candidate #{variant_id} is not loop-backed")
    end

    def variants(conversation, turn_public_id)
      @steward_client.workspace(@workspace_public_id).conversation(conversation).turns.variants(turn_public_id)
    end

    def reply_variant(conversation) = reply_turn(conversation).active_variant

    def reply_turn(conversation)
      rows = turns(conversation)
      rows.reverse.find { |turn| turn.active_variant&.loop_backed? } || rows.last
    end

    # THE OPENING TURN: through rho every turn is a `direct_reply` whose
    # text is the person's words (`rho do` and `rho say` alike — no
    # `message` turn precedes a reply), so a rewind names the turn ABOVE
    # which the first write stands: the opening, non-writing one.
    def opening_turn(conversation) = turns(conversation).min_by(&:position)

    def turns(conversation)
      @steward_client.workspace(@workspace_public_id).conversation(conversation).turns.list(limit: 50).items
    end

    def tool_task(loop_row, name)
      loop_row.tasks.find { |task| task.kind == "tool_task" && task.tool_name == name } ||
        flunk("the mock never called #{name}: #{loop_row.tasks.map(&:tool_name).inspect}")
    end

    def edit_args(path, old_text, new_text)
      { "path" => path, "edits" => [{ "oldText" => old_text, "newText" => new_text }] }
    end

    def script(*calls)
      encoded = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{encoded.join(",")} -- run what the script says"
    end

    def read_root(path)
      full = File.join(@root, path)
      File.file?(full) ? File.read(full, encoding: Encoding::UTF_8) : nil
    end

    def loops = @steward_client.workspace(@workspace_public_id).agent_loops

    def await_active_conversation
      await("no conversation became active") do
        loops.list(status: "running", order: "desc", limit: 5).items.first&.turn&.conversation_public_id
      end
    end

    def await_loop_status(loop_id, wanted)
      latest = nil
      await("the loop never reached #{wanted}; last seen #{latest.inspect}") do
        row = loops.fetch(loop_id)
        latest = row.status
        flunk "the loop #{loop_id} halted: #{row.failure_reason.inspect}" if latest == "failed" && wanted != "failed"
        latest == wanted ? row : nil
      end
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        found = yield
        return found if found
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
