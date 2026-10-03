require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/fixture_project"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"
require_relative "../../nexus/lib/nexus/skills"

# SKILLS AS DOCUMENTS: a skill is content with a scope — a kernel row under `skills/<name>` on the
# workspace or the person's rung, or a `SKILL.md` a runner announces from its checkout — merged by
# the kernel into ONE catalog the model reads in its turn's `skills` block, and loaded through ONE
# `skill` tool whose call is routed by its name's SOURCE: an announced name to its announcer's
# inbox, every other name in-process. Driven through the CLI: `rho skills push|show|rm`, `rho
# skills`, `rho env`, `rho do --runner`, and `rho request LOOP_ID TASK_KEY` — the seed the model
# saw.
#
# THE STEPS, in order on one world: ROWS (the doors' four refusals and one
# write); PUSH (a real SKILL.md split by the CLI, its quoted colon kept);
# LOAD + CLASH + HIDDEN (one loop loads a kernel row in-process and an
# announced name through rho's runner; the block lists three names with
# the clash resolved announced > workspace > user; the wire carries the
# `skill` entry present and unshaped; discovery shows the runner's `skill`
# with no description beside its one document); STABILITY (the same
# sources seal the same bytes; a rewritten description moves exactly its
# line, the tools list not at all); SWITCH (the harness runner bound —
# the block drops the project's name and gains the harness's; the dropped
# name answers `skill_unknown`; the harness's name lands on its inbox as
# a `skill` row with `scope` present); EMPTY (no source anywhere: no
# block, the `skill` entry OMITTED from the wire although rho declared
# it, and the mock's call — a shape no real provider produces — refused
# `skill_unknown` in-process).
#
# ONE CEREMONY PER FILE, TWO GRANTS: the steward's session, the ROOM (an
# account-wide workspace the daemon adopts under `RHO_WORKSPACE`), the
# full-mode daemon on its own home whose work root holds the fixture
# project with `.agents/skills/deploy-notes/SKILL.md`, and the harness
# `ExecutorProcess` as a second runner — granted ACCOUNT-WIDE by the
# founding owner so it serves rho's agent — announcing `documents:
# [echo-notes]` and serving `skill`. The STEWARD is the workspace writer
# (the room is the steward's; the rows are the room's), never the shared
# human; the `user/` rung is the rho steward's, cleaned by teardown. No
# paid lane: whether a MODEL reaches for a listed skill is the bench's.
class SkillsTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 120
  RUNNER_IDENTIFIER = "e2e-skills-runner".freeze
  RUNNER_DISPLAY_NAME = "E2E skills runner".freeze
  HARNESS_TOOLS = %w[slow_read skill].freeze
  HEADER = Nexus::Skills::CATALOG_HEADER
  OMITTED = "Not shown here (too many to include):".freeze
  FIXTURE_SKILLS = File.expand_path("../support/fixtures/skills", __dir__)
  # The project's own skill: the SAME file the fixture dir holds, written
  # into the project the daemon's runner announces from.
  DEPLOY_SKILL = File.read(File.join(FIXTURE_SKILLS, "deploy-notes", "SKILL.md"), encoding: Encoding::UTF_8).freeze
  DEPLOY_DESCRIPTION = "How this project is deployed. Use before any deploy or release step.".freeze
  DEPLOY_BODY_LINE = "This project deploys from `main` only.".freeze
  REVIEW_DESCRIPTION = "Review: how I check a change. Use before approving a pull request or answering a review question.".freeze
  REVIEW_BODY_LINE = "Refuse a change that adds a dependency nobody asked for.".freeze
  COMMIT_DESCRIPTION = "How this team writes commit messages. Use before every commit.".freeze
  COMMIT_DESCRIPTION_REWRITTEN = "How this team writes commit messages, second edition.".freeze
  COMMIT_BODY = "# Commit style\n\nOne line, imperative mood, under 72 characters.\n".freeze
  # The workspace's copy of the project's name: must lose to the announced one.
  DEPLOY_WORKSPACE_DESCRIPTION = "The workspace's stale deploy notes.".freeze
  FILES_LINE = "Files for this skill are under".freeze

  World = Struct.new(:daemon, :home, :harness_home, :project, :empty_root, :steward, :actor, :provisioning,
    :room_public_id, :rho_runner, :harness, :chat_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-skills-e2e")
      harness_home = Dir.mktmpdir("e2e-skills-runner")
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room = steward_client.workspaces.create(
        name: "Skills room #{SecureRandom.hex(3)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).public_id
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room })
      @world = World.new(daemon: daemon, home: home, harness_home: harness_home, steward: steward, actor: actor,
        provisioning: provisioning, room_public_id: room)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      adopted = await_workspace_adopted(daemon)
      raise "the daemon adopted #{adopted.dig("workspace", "public_id")} instead of the room #{room}" unless
        adopted.dig("workspace", "public_id") == room

      @world.rho_runner = adopted.dig("identity", "runner_executor_public_id") ||
        raise("a full-mode rho registers a runner row: #{adopted["identity"].inspect}")
      E2E.enable_dev_lane!
      E2E.hosts.start
      # The project the daemon's runner announces from: one skill under
      # the agentskills layout, and an empty root for the EMPTY step.
      @world.project = E2E::FixtureProject.write(home, "project", {
        ".agents/skills/deploy-notes/SKILL.md" => DEPLOY_SKILL,
        "README.md" => "A project with one skill.\n",
      }).root
      @world.empty_root = File.join(home, "empty").tap { |dir| FileUtils.mkdir_p(dir) }
      @world.chat_public_id = steward_client.workspace(room).conversations
        .create(title: "Skills rows", idempotency_key: SecureRandom.uuid).public_id
      @world.harness = grant_and_start_harness_runner(base_url, provisioning, harness_home)
      @world
    end

    # THE SECOND GRANT (the `handoff` form): the founding owner walks the machine page so the
    # harness runner is ACCOUNT-WIDE — eligible for rho's agent, whose conversation `rho do
    # --runner` binds to it. The credential reaches the child on stdin; it announces the skill
    # module's one document beside `slow_read` and `skill`.
    def grant_and_start_harness_runner(base_url, provisioning, harness_home)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        runner_identifier: RUNNER_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME
      )
      provisioning.with_owner_browser do |owner|
        E2E::RunnerGrant.visit_connection(actor: owner, authorization: authorization)
        offer = E2E::RunnerGrant.scope_offer(owner)
        raise "the skills runner must be account-wide, and the owner's page offered #{offer.inspect}" unless
          %i[selector account_wide].include?(offer)

        E2E::RunnerGrant.connect_in_browser(actor: owner, authorization: authorization,
          account_wide: offer == :selector, existing_runner_scope: (offer if offer == :account_wide))
      end
      credentials = device.await_credentials(authorization)
      root = File.join(harness_home, "tree").tap { |dir| FileUtils.mkdir_p(dir) }
      process = E2E::ExecutorProcess.new(base_url: base_url, home: harness_home,
        credential: credentials.executor_access_token, tools: HARNESS_TOOLS, environment: root)
      process.start
      raise "the harness announced #{process.announced_documents.inspect}" unless process.announced_documents == ["echo-notes"]

      process
    end

    def await_workspace_adopted(daemon)
      daemon.await("the daemon never reported workspace adopted") do
        document = daemon.status
        workspace = document["workspace"]
        raise "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        document if workspace&.fetch("state") == "adopted"
      end
    end

    def stop_world!
      world = @world
      @world = nil
      return if world.nil?

      begin
        # LIST, THEN DELETE — the same shape as `clear_steward_skill_rows`,
        # because by here there is normally nothing left: step 6 removes the
        # row and the test's own `ensure` clears the rung whatever step
        # stopped. This runs for the case where the lane died before
        # `@client` existed. Deleting unconditionally meant a 404 on every
        # GREEN run, and its warning reads exactly like the real cleanup
        # failure this warning exists to raise.
        client = CybrosAgent::Client.new(base_url: E2E.base_url, credential: world.steward.member_token)
        client.profile.memory.list.select { |document| document.path.start_with?("user/skills/") }.each do |document|
          client.profile.memory.delete(document.path, expected_public_id: document.public_id,
            expected_lock_version: document.lock_version)
        end
      rescue StandardError => error
        warn "Could not delete the steward's skill rows after the skills lane: #{error.class}: #{error.message}"
      end
      begin
        world.harness&.stop
      rescue StandardError => error
        warn "Could not stop the harness runner: #{error.class}: #{error.message}"
      end
      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.harness_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
    end
  end

  Minitest.after_run { SkillsTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @harness = @world.harness
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @loops = @client.workspace(@room).agent_loops
    @memory = @client.workspace(@room).conversation(@world.chat_public_id).memory
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    warn_log(@harness&.log_path, "harness runner log")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the skills E2E logs: #{error.class}: #{error.message}"
  end

  def test_skills_are_merged_into_the_turns_block_and_loaded_by_source
    await_rho_ready
    # THE ROOT IS THE PROJECT: the daemon booted on its identity work root (no skill there —
    # `documents=0`), and `rho do --dir` moves a loop's directory, never the runner's root; `rho env
    # DIR` is the one root move, and the move re-scans and re-announces.
    placed = rho("env", @world.project)
    assert_includes placed, @world.project
    await_announced_documents(@world.rho_runner, ["deploy-notes"])

    the_doors_refuse_by_word_and_write_the_workspace_row
    the_cli_pushes_a_real_skill_file_and_lists_three_sections
    first = one_loop_loads_a_kernel_row_in_process_and_an_announced_name_through_the_runner
    the_same_sources_seal_the_same_bytes_and_a_rewrite_moves_one_line(first)
    the_harness_runner_bound_swaps_the_announced_tier_and_takes_its_own_load
    the_empty_merge_seals_no_block_and_omits_the_entry_from_the_wire(first)
  ensure
    # The one residue another lane can read — the rho steward's `user/`
    # rung (the room is this lane's own) — cleared here whatever step
    # stopped, not only at the world's end; step 6 already removed it on
    # the happy path.
    clear_steward_skill_rows
  end

  private

    def clear_steward_skill_rows
      @client.profile.memory.list.select { |document| document.path.start_with?("user/skills/") }.each do |document|
        @client.profile.memory.delete(document.path, expected_public_id: document.public_id,
          expected_lock_version: document.lock_version)
      rescue StandardError => error
        warn "Could not delete #{document.path} after the skills lane: #{error.class}: #{error.message}"
      end
    rescue StandardError => error
      warn "Could not list the steward's skill rows after the skills lane: #{error.class}: #{error.message}"
    end

    # ---- 1. ROWS: the door's five words ----

    def the_doors_refuse_by_word_and_write_the_workspace_row
      written = @memory.write("workspace/skills/commit-style", COMMIT_BODY, description: COMMIT_DESCRIPTION, expected_public_id: nil, expected_lock_version: nil)
      assert_equal "workspace/skills/commit-style", written.path
      assert_equal COMMIT_DESCRIPTION, written.description, "the description is a row fact the door reads back"

      assert_refused("skill_description_required") { @memory.write("workspace/skills/no-description", "body", expected_public_id: nil, expected_lock_version: nil) }
      assert_refused("skill_scope_unavailable") do
        @memory.write("conversation/skills/x", "body", description: "A conversation is never a skill's scope.", expected_public_id: nil, expected_lock_version: nil)
      end
      assert_refused("memory_description_invalid") do
        @memory.write("workspace/notes.md", "a plain note", description: "A plain document has no description.", expected_public_id: nil, expected_lock_version: nil)
      end
      assert_refused("skill_name_invalid") { @memory.write("workspace/skills/PDF", "body", description: "Upper case.", expected_public_id: nil, expected_lock_version: nil) }
      assert_equal ["workspace/skills/commit-style"], @memory.list.map(&:path).grep(%r{\Aworkspace/}),
        "the four refusals wrote nothing; the room's rung holds the one skill"
    end

    # ---- 2. PUSH: the CLI's split of a real SKILL.md ----

    def the_cli_pushes_a_real_skill_file_and_lists_three_sections
      pushed = rho("skills", "push", File.join(FIXTURE_SKILLS, "review-checklist"), "--scope", "user")
      assert_match(%r{^pushed:\s+user/skills/review-checklist \(\d+ bytes\)$}, pushed)
      row = @client.profile.memory.read("user/skills/review-checklist")
      assert_equal REVIEW_DESCRIPTION, row.description, "the quoted colon survived the split"
      refute_includes row.content, "---", "the body carries no frontmatter"
      assert_includes row.content, REVIEW_BODY_LINE

      listed = rho("skills")
      assert_includes listed, "user/\n  review-checklist: #{REVIEW_DESCRIPTION}"
      assert_includes listed, "workspace/\n  commit-style: #{COMMIT_DESCRIPTION}"
      assert_includes listed, "project (announced by this runner)\n  deploy-notes: #{DEPLOY_DESCRIPTION}"

      shown = rho("skills", "show", "review-checklist", "--scope", "user")
      assert_includes shown, REVIEW_BODY_LINE
      refute_includes shown, "description:", "the body alone, without the frontmatter"
    end

    # ---- 3. LOAD + CLASH + HIDDEN ----

    # One loop: `commit-style` (a workspace row, in-process), `deploy-notes`
    # (announced by rho's runner; the workspace's copy of the name loses),
    # `memory_ls` (sees the rows as storage) and `memory_write` on a
    # `skills/` path (refused: an agent never authors its own instructions).
    def one_loop_loads_a_kernel_row_in_process_and_an_announced_name_through_the_runner
      @memory.write("workspace/skills/deploy-notes", "stale body", description: DEPLOY_WORKSPACE_DESCRIPTION, expected_public_id: nil, expected_lock_version: nil)
      calls = [
        skill_call("commit-style"), skill_call("deploy-notes"), "memory_ls:#{arguments({})}",
        "memory_write:#{arguments({ "path" => "workspace/skills/commit-style", "content" => "x" })}",
      ]
      loop_id = rho_do("!mock tool_call=#{calls.join(",")} -- done", @world.project)
      completed = await_completed(loop_id)

      # THE BLOCK the model saw, through the CLI and the SDK — one seed.
      sealed = seed_of(loop_id)
      block = block_of(sealed)
      assert_equal <<~TEXT.chomp, block, "announced > workspace > user; the clash resolved to the announced description"
        #{HEADER}
        - deploy-notes: #{DEPLOY_DESCRIPTION}
        - commit-style: #{COMMIT_DESCRIPTION}
        - review-checklist: #{REVIEW_DESCRIPTION}
      TEXT
      refute_includes block, OMITTED
      assert_equal block, block_of(cli_request(loop_id, "r1")), "`rho request` prints the seed the model saw"
      user_item = sealed.entries.find { |entry| text_of(entry).include?(HEADER) }
      assert_equal "user", user_item.fetch("role"), "the block rides the leading user item, beside memory"
      # The words ride behind the block — in the same item or a later one
      # (the runner's per-request lead sits between them): the seed's
      # texts in order, the catalog before the words.
      whole = sealed.entries.map { |entry| text_of(entry) }.join("\n")
      assert_operator whole.index(HEADER), :<, whole.index("!mock"), "the catalog leads the words"

      # THE WIRE: the entry present, its bytes the kernel's, nothing shaped.
      tools = wired_tools(sealed)
      skill_entries = tools.select { |tool| tool.dig("function", "name") == "skill" }
      assert_equal 1, skill_entries.length, "the skill entry rides the wire once: #{tools.map { |t| t.dig("function", "name") }}"
      assert_equal %w[function], skill_entries.fetch(0).keys.reject { |key| key == "type" }, "a plain function block, no alias facts"
      assert_includes skill_entries.fetch(0).dig("function", "description"), Nexus::Skills::CATALOG_TITLE,
        "the tool's text points at the block's header"

      # THE ROWS: in-process, and through rho's runner.
      commit_row, deploy_row = %w[commit-style deploy-notes].map { |name| skill_row(loop_id, completed, name) }
      assert_equal "completed", commit_row.task.status
      assert_nil commit_row.task.addressed_to, "a kernel row loads in-process: nobody is addressed"
      assert_nil commit_row.task.claimed_by
      assert_equal COMMIT_BODY.strip, commit_row.output.strip, "the row's body is the call's result"

      assert_equal "completed", deploy_row.task.status
      assert_equal "runner", deploy_row.task.addressed_to&.role, deploy_row.task.inspect
      assert_equal @world.rho_runner, deploy_row.task.addressed_to.executor_public_id, "routed to its announcer"
      assert_equal @world.rho_runner, deploy_row.task.claimed_by&.executor_public_id
      assert_includes deploy_row.output, DEPLOY_BODY_LINE, "the SKILL.md body, not the workspace's stale copy"
      refute_includes deploy_row.output, "stale body"
      assert_includes deploy_row.output, "#{FILES_LINE} #{File.join(@world.project, ".agents/skills/deploy-notes")}"
      refute_includes deploy_row.output, "description:", "the frontmatter is stripped"
      assert_includes @daemon.claimed_keys, deploy_row.task.key, "rho's own log says it claimed the row: #{@daemon.claims.inspect}"

      ls_row = task_named(completed, "memory_ls")
      assert_includes @loops.agent_loop(loop_id).task(ls_row.key).output, "workspace/skills/commit-style"
      assert_includes @loops.agent_loop(loop_id).task(ls_row.key).output, "workspace/skills/deploy-notes"
      write_row = task_named(completed, "memory_write")
      assert_includes @loops.agent_loop(loop_id).task(write_row.key).output, "memory_reserved_prefix"
      assert_equal COMMIT_BODY, @memory.read("workspace/skills/commit-style").content, "the model wrote nothing"

      # THE ECHO agrees: the later round carried both bodies as results.
      final = completed.tasks.select(&:round?).map(&:key).last
      echo = @loops.agent_loop(loop_id).task(final).output.to_s
      assert_includes echo, "One line, imperative mood"
      assert_includes echo, DEPLOY_BODY_LINE

      # DISCOVERY: rho's runner announces `skill` with no description
      # (the hidden name rides on that) beside its one document. That the
      # loop RAN under rho's declaration is the hidden-name fact: a
      # declaration carrying the runner's `skill` beside the kernel's would
      # have been refused `duplicate_tool_name` at compile.
      runner = @client.executors.show(@world.rho_runner)
      assert_includes runner.tool_names, "skill"
      assert_nil runner.served_tools.find { |tool| tool.name == "skill" }.description
      assert_equal ["deploy-notes"], runner.document_names
      assert_equal DEPLOY_DESCRIPTION, runner.served_documents.fetch(0).description

      { block: block, tools: tools }
    end

    # ---- 4. STABILITY (K-mf3 on a world) ----

    def the_same_sources_seal_the_same_bytes_and_a_rewrite_moves_one_line(first)
      again = rho_do("!mock tool_call=#{skill_call("commit-style")} -- again", @world.project)
      await_completed(again)
      sealed = seed_of(again)
      assert_equal first.fetch(:block), block_of(sealed), "the same sources render the same bytes"
      assert_equal first.fetch(:tools), wired_tools(sealed), "the tools list is untouched"

      observed = @memory.read("workspace/skills/commit-style")
      @memory.write(observed.path, COMMIT_BODY, description: COMMIT_DESCRIPTION_REWRITTEN,
        expected_public_id: observed.public_id, expected_lock_version: observed.lock_version)
      moved = rho_do("!mock tool_call=#{skill_call("commit-style")} -- once more", @world.project)
      await_completed(moved)
      sealed = seed_of(moved)
      changed = first.fetch(:block).lines.zip(block_of(sealed).lines).reject { |before, after| before == after }
      assert_equal [["- commit-style: #{COMMIT_DESCRIPTION}\n", "- commit-style: #{COMMIT_DESCRIPTION_REWRITTEN}\n"]], changed,
        "exactly the rewritten line moved"
      assert_equal first.fetch(:tools), wired_tools(sealed), "a row write never moves the tool list"
    end

    # Switch runners and verify document routing through a non-rho announcer.

    def the_harness_runner_bound_swaps_the_announced_tier_and_takes_its_own_load
      # The CLASH row served step 3 (announced > workspace); retired here so
      # the switch leaves `deploy-notes` with NO source — the design's pin:
      # the block drops it and its load answers `skill_unknown`, never the
      # workspace's stale copy (which a kernel-row load would rightly find).
      rho("skills", "rm", "deploy-notes", "--scope", "workspace")
      loop_id = rho_do("!mock tool_call=#{skill_call("deploy-notes")},#{skill_call("echo-notes")} -- done",
        @world.project, "--runner", @harness.executor_public_id)
      completed = await_completed(loop_id)

      block = block_of(seed_of(loop_id))
      assert_equal <<~TEXT.chomp, block, "the runner switch dropped the project's skill and kept the room's and the person's"
        #{HEADER}
        - echo-notes: Echoes a skill load (E2E harness executor).
        - commit-style: #{COMMIT_DESCRIPTION_REWRITTEN}
        - review-checklist: #{REVIEW_DESCRIPTION}
      TEXT

      dropped = skill_row(loop_id, completed, "deploy-notes")
      assert_nil dropped.task.addressed_to, "a name nobody announces now runs in-process"
      assert_equal "skill_unknown: deploy-notes", dropped.output.strip,
        "the withdrawn source withdrew its declaration: the error result, never a stale copy"

      echoed = skill_row(loop_id, completed, "echo-notes")
      assert_equal "runner", echoed.task.addressed_to&.role, echoed.task.inspect
      assert_equal @harness.executor_public_id, echoed.task.addressed_to.executor_public_id,
        "a load of an announced name reaches a NON-rho announcer's inbox"
      assert_equal @harness.executor_public_id, echoed.task.claimed_by&.executor_public_id
      assert_equal %(echo:skill:{"name":"echo-notes"}), echoed.output.strip, "the harness's echo is the result"
      claim = @harness.inbox_claims.find { |line| line["task"] == echoed.task.key }
      refute_nil claim, "the harness claimed the row: #{@harness.inbox_claims.inspect}"
      assert_equal "skill", claim.fetch("tool_name"), "the same `skill` row, addressed to its announcer"
      assert_nil claim.fetch("tool_alias"), "rho spells the kernel's own name"
      assert_equal true, claim.fetch("scope_present"), "a kernel name on an inbox carries the scope stamp"
    end

    # ---- 6. EMPTY MERGE: two facts, two witnesses ----

    def the_empty_merge_seals_no_block_and_omits_the_entry_from_the_wire(first)
      moved = rho("env", @world.empty_root)
      assert_includes moved, @world.empty_root
      await_announced_documents(@world.rho_runner, [])
      rho("skills", "rm", "commit-style", "--scope", "workspace")
      rho("skills", "rm", "review-checklist", "--scope", "user")
      assert_empty @memory.list.map(&:path).grep(%r{skills/}), "both rungs are clear"
      assert_empty @client.profile.memory.list.map(&:path).grep(%r{skills/})

      loop_id = rho_do("!mock tool_call=#{skill_call("anything")} -- done", @world.empty_root)
      completed = await_completed(loop_id)
      sealed = seed_of(loop_id)
      refute(sealed.entries.any? { |entry| text_of(entry).include?(HEADER) }, "no source, no block")

      # (1) THE WIRE PIN: the entry OMITTED although rho declared it — the
      # rest of the list byte for byte what the first loop sent.
      tools = wired_tools(sealed)
      refute(tools.any? { |tool| tool.dig("function", "name") == "skill" }, "the skill entry is absent, not disabled")
      assert_equal first.fetch(:tools).reject { |tool| tool.dig("function", "name") == "skill" }, tools,
        "the stored set minus the one entry, nothing else shaped"

      # (2) THE KERNEL'S REFUSAL PATH: the mock still emits the call (its
      # gate is "any tools declared"), the kernel resolves it from the
      # STORED set, runs it in-process and answers `skill_unknown` — a
      # shape no real provider produces, pinned as the refusal, never as
      # a model behaviour.
      row = skill_row(loop_id, completed, "anything")
      assert_nil row.task.addressed_to
      assert_equal "skill_unknown: anything", row.output.strip
    end

    # ---- the CLI ----

    def rho(*args)
      output, status = @daemon.cli(*args)
      assert_predicate status, :success?, "rho #{args.first} failed:\n#{output}"
      output
    end

    # `rho do`, the shipped verb: the loop backing the turn.
    def rho_do(prompt, directory, *flags)
      output = rho("do", prompt, "--model", MODEL, "--dir", directory, *flags)
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, "rho do printed no loop id:\n#{output}"
      loop_id
    end

    # `rho request LOOP_ID TASK_KEY`: the sealed entries, parsed past
    # whatever the runtime prints ahead of them.
    def cli_request(loop_id, task_key)
      output = rho("request", loop_id, task_key)
      entries = JSON.parse(output.split("entries:\n", 2).fetch(1))
      CybrosAgent::Api::SealedRequest.new(entries: entries, request_options: {})
    end

    # THE DIRECTIVE, as the mock parses it: url-encoded JSON that parses.
    def skill_call(name) = "skill:#{arguments({ "name" => name })}"

    def arguments(hash) = CGI.escape(JSON.generate(hash))

    # ---- the reads ----

    def await_rho_ready
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      @daemon.await("rho never declared its profile") do
        @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
    end

    # Discovery's document list for an executor — the announcement the
    # kernel merges from, re-sent on every root move.
    def await_announced_documents(executor_public_id, names)
      await("#{executor_public_id} never announced documents #{names.inspect}") do
        listed = @client.executors.show(executor_public_id)
        listed if listed.document_names == names
      end
    end

    def await_completed(loop_id)
      await("the loop #{loop_id} never completed") do
        row = @loops.fetch(loop_id)
        flunk "the loop failed: #{row.failure_reason.inspect} #{summarize(row)}" if row.status == "failed"
        row if row.status == "completed"
      end
    end

    # THE SEED the model saw: the loop's round one, sealed once at the turn.
    def seed_of(loop_id) = @loops.agent_loop(loop_id).tasks_context("r1").request

    def wired_tools(sealed) = sealed.request_options.fetch("tools")

    # The block is one part of the leading user item — a merged message
    # keeps each block its own part — whose paragraph is the header and
    # its lines, joined by single newlines.
    def block_of(sealed)
      texts = sealed.entries.flat_map { |entry| Array(entry["parts"]).map { |part| part["text"].to_s } }
      paragraph = texts.flat_map { |text| text.split("\n\n") }.find { |part| part.start_with?(HEADER) }
      refute_nil paragraph, "no skills block in the seed: #{texts.inspect}"
      paragraph
    end

    def text_of(entry) = Array(entry["parts"]).map { |part| part["text"].to_s }.join

    # The `skill` row whose input names `name`: the task detail (its
    # output and input) with the loop row's own task (its addressing).
    def skill_row(loop_id, completed, name)
      candidates = completed.tasks.select { |task| task.tool_name == "skill" }
      detail = candidates.map { |task| @loops.agent_loop(loop_id).task(task.key) }
        .find { |row| row.tool_input.is_a?(Hash) && row.tool_input["name"] == name }
      refute_nil detail, "the model never loaded #{name}: #{summarize(completed)}"
      detail
    end

    def task_named(completed, tool_name)
      task = completed.tasks.find { |row| row.tool_name == tool_name }
      refute_nil task, "the model never called #{tool_name}: #{summarize(completed)}"
      task
    end

    def summarize(row)
      row.tasks.map { |task| "#{task.key}(#{task.kind}/#{task.status}#{task.tool_name ? ":#{task.tool_name}" : ""})" }.join(" ")
    end

    def assert_refused(code)
      error = assert_raises(CybrosAgent::Api::InvalidRequest) { yield }
      assert_equal code, error.code, "the door's word: #{error.message}"
    end

    def await(message)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
