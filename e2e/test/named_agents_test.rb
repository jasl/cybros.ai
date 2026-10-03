require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# NAMED SUB-AGENT DEFINITIONS THROUGH exe/rho (two homes with separate durable state): a checkout's
# `.agents/agents/<name>.md` is read at the daemon's environment root and registered in Nexus as a
# DERIVED INSTANCE PROFILE of this rho — an Agent Profile with the handle `@<name>`, the identifier
# `rho.<instance>/<name>`, the file's description, the file's body as its `system_prompt`, the
# parent's tool set narrowed to the file's `tools:` — so `spawn {agent: "@reviewer"}` resolves
# through the ONE resolver unchanged. The spawner learns the definitions from the ROSTER rho writes
# into its own `system_prompt` slot beside the guideline. `rho agents publish NAME` flips the SAME
# row to the steward's scope: it survives its file, every agent of the steward sees it and spawns
# it, and the FLOOR — rho's Guard, the install's protected roots on every task the runner serves —
# refuses the write such a child would make under the spawning home. The model selection behavior is
# landed: the file's `model:` is the row's `default_model`, the first choice in model selection; a
# row without one answers on the initiator's.
#
# The mock provider ECHOES its joined input and reads directives on line
# 1, so every pin here reads a ROW the kernel wrote (the daemon's listing
# relays the kernel's rows), a byte rho authored (the slot, the printed
# lines) or a sealed request — never a model's judgement (the paid lane
# `live_named_agent` is the round's window).
#
# ONE CEREMONY PER FILE (the `rho_spawn` two-daemon shape): the steward's
# session, the ROOM and home A's daemon — its environment root a directory
# the journey owns, OUTSIDE the home, carrying four definitions before the
# boot so the boot's own declare edge reads them — are booted once for
# every case; home B (the published clause) once more, on its first use;
# both stop when the run ends. The cases are order-independent: each
# reads the STEADY STATE (four instance rows: reviewer, docs, strong,
# fixer) and the two that move it put it back in their `ensure`.
class NamedAgentsTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  STRONG_MODEL = "dev/mock-text-only".freeze
  POLL = 1
  AWAIT_SECONDS = 120

  # ---- the definition files ----

  REVIEWER_DESCRIPTION = "Reviews a change for defects and reports only what matters; use it after a change lands.".freeze
  REVIEWER_BODY = "REVIEWER-BODY-7: read what the spawner names and report only what matters.".freeze
  REVIEWER = <<~MD.freeze
    ---
    name: reviewer
    description: #{REVIEWER_DESCRIPTION}
    tools: read, grep
    ---
    #{REVIEWER_BODY}
  MD
  DOCS_DESCRIPTION = "Writes the docs for a change and answers with the paths it wrote.".freeze
  DOCS = <<~MD.freeze
    ---
    description: #{DOCS_DESCRIPTION}
    tools: []
    ---
    Write the docs the spawner names and answer with the paths.
  MD
  STRONG_DESCRIPTION = "Thinks longer about a hard question and answers in one paragraph.".freeze
  STRONG = <<~MD.freeze
    ---
    description: #{STRONG_DESCRIPTION}
    model: #{STRONG_MODEL}
    ---
    STRONG-BODY: answer in one paragraph.
  MD
  # THE PUBLISHED ONE carries `write`: the reviewer's exact set (`grep,
  # read`, item 1's pin) can never reach the runner with a write, and the
  # floor (item 3) is a veto ON the runner — so the definition published
  # and spawned from home B is the one whose set holds the tool.
  FIXER_DESCRIPTION = "Applies the one-line fix the spawner names and reports the file it wrote.".freeze
  FIXER = <<~MD.freeze
    ---
    description: #{FIXER_DESCRIPTION}
    tools: read, write
    ---
    FIXER-BODY: apply the fix the spawner names, nothing else.
  MD
  DEFINITIONS = { "reviewer" => REVIEWER, "docs" => DOCS, "strong" => STRONG, "fixer" => FIXER }.freeze
  NOTE_LINE = "The named-agents project has one note.".freeze

  # ---- rho's model-facing bytes, exactly as the design records them ----

  GUIDELINE_OPENING = "You can call several tools in one message.".freeze
  ROSTER_HEADING = "Agents here you can hand work to by @handle (the `agent` argument of a spawn or a send); " \
                   "each starts with an empty context, answers with its own tools, and reports back to you:".freeze
  # `Rho::LoopRequest::INCUBATION`, the reason the floor's veto carries.
  INCUBATION = "an agent never edits its own checkout or home; develop a successor as a separate install".freeze

  World = Struct.new(:daemon, :home, :root, :steward, :actor, :room_public_id, :room_name,
    :profile, :handle, :identifier, :runner,
    :peer_daemon, :peer_home, :peer_root, :peer_profile, :peer_handle, :peer_runner, keyword_init: true)

  class << self
    attr_reader :world

    # The file's one ceremony: the steward opens an account-wide room, the
    # dev lane is enabled BEFORE the boot (strong.md's model is judged at
    # the boot's own declare edge — an unauthorized ref is that file's
    # `agents.declaration_failed`, not a row), home A boots under the room
    # knob with its environment root pointed at a directory of the
    # journey's carrying the four definitions and one note to read.
    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      E2E.enable_dev_lane!
      home = Dir.mktmpdir("rho-named-agents-e2e")
      root = Dir.mktmpdir("rho-named-agents-root")
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room_name = "Named agents room #{SecureRandom.hex(3)}"
      room = steward_client.workspaces.create(
        name: room_name, access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).public_id
      File.write(File.join(root, "NOTES.md"), "#{NOTE_LINE}\n", encoding: Encoding::UTF_8)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room },
        tools_root: root, definitions: DEFINITIONS)
      @world = World.new(daemon: daemon, home: home, root: root, steward: steward, actor: actor,
        room_public_id: room, room_name: room_name)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      adopted = await_workspace_adopted(daemon)
      raise "home A adopted #{adopted} instead of the room #{room}" unless adopted == room

      await_named_definitions(daemon, DEFINITIONS.keys)
      E2E.hosts.start
      @world
    end

    # The boot declares the files' rows on the bind edge AFTER adoption, in
    # its own fiber: a listing read straight after adoption raced it under
    # the four-world gate (two nil rows on 2026-09-16; green solo). The
    # listing carrying every file's row is the boot's observable truth.
    def await_named_definitions(daemon, names)
      daemon.await("the boot never declared the files' rows #{names.inspect}") do
        listed = daemon.control(:get, "/agents").fetch("agents").fetch("instance").map { |row| row["name"] }
        (names - listed).empty? ? listed : nil
      end
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

      [world.daemon, world.peer_daemon].compact.each do |daemon|
        daemon.stop
      rescue StandardError => error
        warn "Could not stop a rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.root, world.peer_home, world.peer_root].compact.each do |dir|
        FileUtils.remove_entry(dir) if File.directory?(dir)
      end
    end
  end

  Minitest.after_run { NamedAgentsTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout (home A)")
    warn_log(@daemon&.rho_log_path, "rho structured log (home A)")
    warn_log(@world&.peer_daemon&.log_path, "rho daemon stdout (home B)")
    warn_log(@world&.peer_daemon&.rho_log_path, "rho structured log (home B)")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the named agents E2E logs: #{error.class}: #{error.message}"
  end

  # ITEM 1 — A FILE-DEFINED AGENT, SPAWNED BY NAME. The boot's declare edge read the files: `rho
  # agents` lists them under `instance/` with the design's columns; the daemon's listing relays the
  # kernel's rows — `scope: instance`, derived from A's profile, the composed identifier, the
  # reviewer's set EXACTLY `grep, read` (no kernel name, no bash), docs's `[]` with the parent's
  # mode; A's slot is the guideline then the roster with one line per agent. A spawn of `@reviewer`
  # from A's turn: the child is answered by the reviewer's row on the spawner's model, its seed
  # carries the file's body as the first system item and no roster, its runner is A's — the child's
  # `read` is claimed on home A — and the reply relays as the `<task_result …>` envelope; `rho
  # watch` names the reviewer's row as the child's answerer.
  def test_a_file_defined_agent_is_listed_declared_rostered_and_spawned_by_name_on_the_spawners_runner
    profile, handle = rho_identity(@daemon)
    listed, status = @daemon.cli("agents")
    assert_predicate status, :success?, "rho agents failed:\n#{listed}"
    assert_match(%r{^instance/  \(\.agents/agents, \.claude/agents under #{Regexp.escape(@world.root)}\)$}, listed,
      "the instance section names the two directories at the environment root:\n#{listed}")
    assert_match(/^  @reviewer   reviewer   #{Regexp.escape(REVIEWER_DESCRIPTION)}   model: —   fallback: —   tools: grep, read$/, listed, listed)
    assert_match(%r{^    \.agents/agents/reviewer\.md$}, listed, "the file, relative to the root:\n#{listed}")
    assert_match(/^  @docs   docs   #{Regexp.escape(DOCS_DESCRIPTION)}   model: —   fallback: —   tools: none$/, listed, listed)
    refute_match(/^skipped:/, listed, "every file is a definition:\n#{listed}")

    reviewer = instance_row("reviewer")
    docs = instance_row("docs")
    assert_equal %w[instance reviewer reviewer], reviewer.values_at("scope", "name", "handle")
    assert_equal profile, reviewer["derived_from_public_id"], "derived from A's own profile"
    assert_equal "#{@world.identifier}/reviewer", reviewer["agent_identifier"], "the identifier the door composed"
    assert_equal "#{@world.identifier}/docs", docs["agent_identifier"]
    assert_equal %w[grep read], tool_names(reviewer), "the reviewer's set is EXACTLY the file's allowlist"
    assert_nil reviewer.dig("configuration", "default_model"), "no model in the file, none on the row"
    assert_equal [], tool_names(docs), "`tools: []` is none"
    assert_equal "bypass", docs.dig("configuration", "approval_mode"), "the parent's mode is written for an empty set too"

    slot = rho_slot(@daemon)
    heading = slot.index(ROSTER_HEADING)
    refute_nil heading, "the roster heading follows the guideline in rho's own slot:\n#{slot}"
    assert_operator heading, :>, slot.index(GUIDELINE_OPENING), "the guideline leads"
    roster = slot[heading..]
    assert_equal 1, roster.scan(/^- @reviewer: /).length, "one line per name:\n#{roster}"
    assert_match(/^- @reviewer: #{Regexp.escape(REVIEWER_DESCRIPTION)} \(tools: grep, read\)$/, roster, roster)
    assert_equal 1, roster.scan(/^- @docs: /).length, roster
    assert_match(/^- @docs: #{Regexp.escape(DOCS_DESCRIPTION)} \(tools: none\)$/, roster, roster)

    a_claims = @daemon.claims.length
    brief = script([["read", { "path" => "NOTES.md" }]], "reviewer done")
    conversation, _turn, loop = rho_do(script([["spawn", { "prompt" => brief, "agent" => "@reviewer", "label" => "review" }]], "spawned"))
    await_loop_status(loop, "completed")
    chat = @conversations.conversation(conversation)
    child = await_child(chat, label: "review")
    assert_equal reviewer.fetch("public_id"), child.answering_user_public_id, "the named row answers the child"
    assert_includes task_result(loop, "r2t0"),
      "Spawned conversation #{child.public_id} (label review), answered by @reviewer, in the background"

    child_chat = @conversations.conversation(child.public_id)
    reply = await_reply(child_chat, after: -1)
    child_loop = reply.active_variant.agent_loop_public_id
    assert_equal MODEL, loop_row(child_loop).dig("turn", "model", "model"),
      "F-3 step 3: a row without a model answers on the initiator's — the spawner's turn"
    assert_equal @world.runner, child_chat.fetch.runner&.executor_public_id, "the child inherits A's bound runner"
    entries = sealed_entries(child_loop, "r1")
    assert_equal "system", entries.first.fetch("role"), "the file's body is the first system item: #{entries.first.inspect}"
    assert text_of(entries.first).start_with?(REVIEWER_BODY),
      "the child's system_prompt slot is the file's body:\n#{text_of(entries.first)}"
    refute_includes texts_of(entries).join("\n"), ROSTER_HEADING, "a named row renders no roster of itself"
    assert_includes task_result(child_loop, "r2t0"), NOTE_LINE, "the child's read ran against the parent's root"
    assert_equal a_claims + 1, @daemon.claims.length, "home A's runner claimed the child's read: #{@daemon.claims.inspect}"
    assert_equal "read", @daemon.claims.last.fetch("tool")

    woken = await_feed(conversation, "the reviewer's reply was never mailed") { |items| new_turns(items, except: [loop]).first }
    woken_loop = woken.dig("payload", "agent_loop_public_id")
    await_loop_status(woken_loop, "completed")
    seed = sealed_texts(woken_loop, "r1").join("\n")
    assert_includes seed, %(<task_result task="r2t0" status="completed" conversation="#{child.public_id}">),
      "the reply relays as the envelope naming the call and the child:\n#{seed}"
    assert_includes seed, "reviewer done", seed

    watched, status = @daemon.cli("watch", conversation, "--timeout", E2E::RhoDaemon::WATCH_TIMEOUT.to_s)
    assert_predicate status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/^  spawned\s+#{Regexp.escape(child.public_id)} \(review, r2t0\) answered by #{Regexp.escape(reviewer.fetch("public_id"))} — /,
      watched, "the child tree names the reviewer's row as the answerer:\n#{watched}")
    assert_match(/^    from: @#{Regexp.escape(handle)} \(agent\) #{Regexp.escape(child.public_id)}$/, watched,
      "the mail is authored by the parent loop's creator and stamped with the child:\n#{watched}")
  end

  # ITEM 2 — THE MODEL HALF. `strong.md` names the harness's text-only twin: the row carries it as
  # `default_model`, `rho agents` prints it, and a spawn of `@strong` yields a child whose first
  # turn runs on it while the spawner's own turn ran on `dev/mock-text`.
  def test_a_files_model_is_the_rows_default_model_and_the_childs_turn_runs_on_it
    strong = instance_row("strong")
    assert_equal STRONG_MODEL, strong.dig("configuration", "default_model"), strong.inspect
    assert_equal STRONG_MODEL, strong["model"]
    listed, status = @daemon.cli("agents")
    assert_predicate status, :success?, listed
    assert_match(/^  @strong   strong   #{Regexp.escape(STRONG_DESCRIPTION)}   model: #{Regexp.escape(STRONG_MODEL)}   fallback: —   tools: /, listed, listed)

    conversation, _turn, loop = rho_do(script([["spawn", { "prompt" => "!mock -- strong hello", "agent" => "@strong", "label" => "strong" }]], "spawned"))
    await_loop_status(loop, "completed")
    assert_equal MODEL, loop_row(loop).dig("turn", "model", "model"), "the spawner's turn ran on the verb's model"
    child = await_child(@conversations.conversation(conversation), label: "strong")
    assert_equal strong.fetch("public_id"), child.answering_user_public_id
    reply = await_reply(@conversations.conversation(child.public_id), after: -1)
    assert_equal STRONG_MODEL, loop_row(reply.active_variant.agent_loop_public_id).dig("turn", "model", "model"),
      "the row's own model is step 0 of the ladder: the child answers on it whatever the spawner ran"
  end

  # ITEM 3 — THE PUBLISHED HOME AND THE FLOOR. `rho agents publish fixer`
  # on A flips the SAME row (public id, handle, identifier unchanged) to
  # `scope: steward`. Home B boots under the same steward in the room: its
  # `rho agents` lists `@fixer` under `nexus/` with `from: @<A>` and no
  # file, its slot roster carries the line, `rho do --agent @fixer` from B
  # is answered by the published row on B's runner, and B's spawn of
  # `@fixer` whose child writes under B's home is VETOED by the floor —
  # the incubation sentence in the call's result, the file absent. Then
  # the durability: A deletes `fixer.md` and syncs — `removed: 0`, the
  # published row stays with no file; A's `rho agents rm fixer` removes
  # it; B's next sync no longer lists it.
  def test_publish_flips_the_same_row_a_second_home_spawns_it_and_the_floor_vetoes_its_write_under_that_home
    _profile, handle = rho_identity(@daemon)
    before = instance_row("fixer")
    published, status = @daemon.cli("agents", "publish", "fixer")
    assert_predicate status, :success?, "rho agents publish failed:\n#{published}"
    assert_match(%r{^published: @fixer \(#{Regexp.escape(@world.identifier)}/fixer\) from \.agents/agents/fixer\.md$}, published, published)
    after = nexus_row("fixer")
    assert_equal before.values_at("public_id", "handle", "agent_identifier"), after.values_at("public_id", "handle", "agent_identifier"),
      "the same row, published"
    assert_equal "steward", after["scope"]
    assert_equal @daemon.definition_path("fixer"), after["path"], "A's own published row still names its file"
    assert_nil instance_row("fixer"), "and is no longer an instance row"

    peer, _peer_profile, _peer_handle = peer_home
    synced, status = peer.cli("agents", "sync")
    assert_predicate status, :success?, "rho agents sync on home B failed:\n#{synced}"
    assert_match(/^declared: 0   removed: 0   skipped: 0$/, synced, "B defines nothing of its own:\n#{synced}")
    listed, status = peer.cli("agents")
    assert_predicate status, :success?, listed
    assert_match(/^  @fixer   fixer   #{Regexp.escape(FIXER_DESCRIPTION)}   model: —   fallback: —   tools: read, write   from: @#{Regexp.escape(handle)}$/,
      listed, "B lists the published row with its publisher:\n#{listed}")
    assert_operator listed.index("nexus/  (published under the steward"), :<, listed.index("  @fixer   fixer"), "under nexus/:\n#{listed}"
    refute_match(%r{^    \.agents/agents/fixer\.md$}, listed, "no file on B:\n#{listed}")
    assert_includes rho_slot(peer), "- @fixer: #{FIXER_DESCRIPTION} (tools: read, write)", "B's roster carries it"

    output, status = peer.cli("do", "!mock -- hello", "--model", MODEL, "--dir", @world.peer_root, "--agent", "@fixer")
    assert_predicate status, :success?, "rho do --agent on home B failed:\n#{output}"
    assert_match(/^agent:\s+@fixer \(#{Regexp.escape(after.fetch("public_id"))}\)$/, output, output)
    conversation = output[/^conversation:\s+(\S+)/, 1]
    loop = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop, output
    chat = @conversations.conversation(conversation).fetch
    assert_equal after.fetch("public_id"), chat.answering_user_public_id, "the published row answers B's conversation"
    assert_equal @world.peer_runner, chat.runner&.executor_public_id, "bound to B's runner"
    await_loop_status(loop, "completed")

    # The denied target is a protected home member: the identity vaults' users/ parent. An unrelated
    # file directly under the home is not a protected member; the work root remains exempt.
    target = File.join(@world.peer_home, "users", "x")
    b_claims = peer.claims.length
    brief = script([["write", { "path" => target, "content" => "not this home's to write" }]], "fixer done")
    conversation, _turn, loop = peer_rho_do(script([["spawn", { "prompt" => brief, "agent" => "@fixer", "label" => "fix" }]], "spawned"))
    await_loop_status(loop, "completed")
    child = await_child(@conversations.conversation(conversation), label: "fix")
    assert_equal after.fetch("public_id"), child.answering_user_public_id
    reply = await_reply(@conversations.conversation(child.public_id), after: -1)
    vetoed = task_result(reply.active_variant.agent_loop_public_id, "r2t0")
    assert_includes vetoed,
      "blocked by rho.guard: write under #{File.join(File.realpath(@world.peer_home), "users")} is refused: #{INCUBATION} " \
      "(refused: #{target})",
      "THE FLOOR: a write under the spawning home's member is refused on B's runner with the incubation reason:\n#{vetoed}"
    refute_path_exists target, "nothing was written"
    assert_equal b_claims + 1, peer.claims.length, "the call was claimed on home B and vetoed there: #{peer.claims.inspect}"
    assert_equal "write", peer.claims.last.fetch("tool")

    @daemon.delete_definition("fixer")
    synced, status = @daemon.cli("agents", "sync")
    assert_predicate status, :success?, "rho agents sync failed:\n#{synced}"
    assert_match(/^declared: 3 \(docs, reviewer, strong\)   removed: 0   skipped: 0$/, synced,
      "a published row is never removed by its file going:\n#{synced}")
    kept = nexus_row("fixer")
    assert_equal after.fetch("public_id"), kept.fetch("public_id"), "the published row stays"
    refute kept.key?("path"), "with no file: #{kept.inspect}"

    removed, status = @daemon.cli("agents", "rm", "fixer")
    assert_predicate status, :success?, "rho agents rm failed:\n#{removed}"
    assert_match(%r{^removed: @fixer \(#{Regexp.escape(@world.identifier)}/fixer\)$}, removed, "no file clause once the file is gone:\n#{removed}")
    assert_nil nexus_row("fixer"), "A's listing no longer holds it"
    synced, status = peer.cli("agents", "sync")
    assert_predicate status, :success?, synced
    listed, status = peer.cli("agents")
    assert_predicate status, :success?, listed
    refute_match(/@fixer/, listed, "B's next edge no longer lists the removed row:\n#{listed}")
  ensure
    restore_definition("fixer", FIXER)
  end

  # ITEM 4 — THE REMOVAL EDGE. Delete `docs.md`; `rho agents sync` prints
  # `removed: 1 (docs)`; the listing and the roster drop it; a spawn of
  # `@docs` answers `answerer_not_eligible`'s sentence (the removed row is
  # still FOUND by handle), a spawn of `@dcos` answers `principal_unknown`
  # naming `@reviewer` and not `@docs`; the file back plus a sync restores
  # the SAME row — public id, handle, identifier.
  def test_a_deleted_file_removes_its_row_reversibly_and_the_two_refusals_read_by_name
    before = instance_row("docs")
    @daemon.delete_definition("docs")
    synced, status = @daemon.cli("agents", "sync")
    assert_predicate status, :success?, "rho agents sync failed:\n#{synced}"
    assert_match(/^declared: 3 \(fixer, reviewer, strong\)   removed: 1 \(docs\)   skipped: 0$/, synced, synced)
    assert_nil instance_row("docs"), "the listing no longer holds the removed row"
    assert_nil nexus_row("docs")
    refute_match(/^- @docs: /, rho_slot(@daemon), "the roster drops it at the same edge")

    conversation, _turn, loop = rho_do(script([
      ["spawn", { "prompt" => "!mock -- docs?", "agent" => "@docs", "label" => "gone" }],
      ["spawn", { "prompt" => "!mock -- dcos?", "agent" => "@dcos", "label" => "typo" }],
    ], "asked"))
    await_loop_status(loop, "completed")
    assert_includes task_result(loop, "r2t0"),
      "agent: @docs cannot answer a conversation here: it is not an agent profile with write standing in this workspace.",
      "a removed row is found by its handle and refused as not eligible"
    unknown = task_result(loop, "r3t0")
    assert_includes unknown, %(agent: "@dcos" names no member of this account. The agents are: ), unknown
    assert_match(/@reviewer(,|$)/, unknown, "the sentence lists the live named rows:\n#{unknown}")
    refute_match(/@docs(,|$)/, unknown, "and never the removed one:\n#{unknown}")
    assert_empty @conversations.conversation(conversation).children.items, "neither refusal minted a child"

    @daemon.write_definition("docs", DOCS)
    synced, status = @daemon.cli("agents", "sync")
    assert_predicate status, :success?, synced
    assert_match(/^declared: 4 \(docs, fixer, reviewer, strong\)   removed: 0   skipped: 0$/, synced, synced)
    restored = instance_row("docs")
    refute_nil restored, "the file back restores the row"
    assert_equal before.values_at("public_id", "handle", "agent_identifier"), restored.values_at("public_id", "handle", "agent_identifier"),
      "the SAME row: public id, handle and identifier"
    assert_match(/^- @docs: #{Regexp.escape(DOCS_DESCRIPTION)} \(tools: none\)$/, rho_slot(@daemon), "and the roster has it back")
  ensure
    restore_definition("docs", DOCS)
  end

  private

    # ---- the mock's script ----

    # `!mock tool_call=<name>:<args>,… -- <remainder>`: one scripted call
    # per round, each with its own url-encoded arguments, then the fake
    # speaks the remainder. A nested brief is a whole script inside the
    # `prompt` argument, escaped with it.
    def script(calls, remainder)
      spelled = calls.map { |name, arguments| "#{name}:#{CGI.escape(JSON.generate(arguments))}" }
      "!mock tool_call=#{spelled.join(",")} -- #{remainder}"
    end

    # ---- the rho half ----

    def rho_do(prompt)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", @world.root)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids_of(output)
    end

    def peer_rho_do(prompt)
      output, status = @world.peer_daemon.cli("do", prompt, "--model", MODEL, "--dir", @world.peer_root)
      assert_predicate status, :success?, "rho do on home B failed:\n#{output}"
      ids_of(output)
    end

    def ids_of(output)
      ids = %w[conversation turn loop].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # THE DAEMON'S LISTING (`GET /agents`): the kernel's rows as the door
    # answers them, the file paths beside them — the one place a journey
    # reads a named row's facts, since the kernel's door is the AGENT
    # bearer's (a steward's token is refused `not_agent_profile`).
    def named_rows = @daemon.control(:get, "/agents").fetch("agents")

    def instance_row(name) = named_rows.fetch("instance").find { |row| row["name"] == name }

    def nexus_row(name) = named_rows.fetch("nexus").find { |row| row["name"] == name }

    def tool_names(row)
      Array(row.dig("configuration", "tool_definitions")).map { |entry| entry.dig("function", "name") }.sort
    end

    # rho's own `system_prompt` slot as `rho prompt show` prints it, from
    # the guideline's first sentence on.
    def rho_slot(daemon)
      output, status = daemon.cli("prompt", "show", "system_prompt")
      assert_predicate status, :success?, "rho prompt show failed:\n#{output}"
      start = output.index(GUIDELINE_OPENING)
      refute_nil start, "rho prompt show printed no system_prompt:\n#{output}"
      output[start..].strip
    end

    # The steady state, back: the file rewritten when it is gone and the
    # edge run once more — the same row restored. A failure here is
    # reported, never raised over the case's own verdict.
    def restore_definition(name, text)
      @daemon.write_definition(name, text) unless File.file?(@daemon.definition_path(name))
      output, status = @daemon.cli("agents", "sync")
      warn "restoring #{name} after the case failed:\n#{output}" unless status.success?
    rescue StandardError => error
      warn "Could not restore #{name}: #{error.class}: #{error.message}"
    end

    # A home's profile, handle, identifier and runner row once its runner
    # has announced and its profile — the named rows with it — is declared.
    def rho_identity(daemon)
      cached = daemon.equal?(@daemon) ? [@world.profile, @world.handle] : [@world.peer_profile, @world.peer_handle]
      return cached if cached.first

      daemon.await("rho never announced its tools") do
        runner = daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      daemon.await("rho never declared its profile") do
        daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
      printed, status = daemon.cli("status")
      assert_predicate status, :success?, "rho status failed:\n#{printed}"
      ids = [printed[/^profile:\s+(\S+)/, 1], printed[/^handle:\s+@(\S+)/, 1]]
      refute_includes ids, nil, "rho status printed no profile or handle line:\n#{printed}"
      own = @client.workspace(@room).principals.find { |principal| principal.public_id == ids.first }
      refute_nil own, "the home's own row is a principal of the room"
      runner = daemon.status.dig("identity", "runner_executor_public_id")
      refute_nil runner, "a full-mode rho registers a runner row"
      if daemon.equal?(@daemon)
        @world.profile, @world.handle = ids
        @world.identifier = own.agent_identifier
        @world.runner = runner
      else
        @world.peer_profile, @world.peer_handle = ids
        @world.peer_runner = runner
      end
      ids
    end

    # HOME B: a second full rho under the same steward and the same room
    # address, its own environment root with no definitions — one more
    # device grant, spent once per file. Answers the daemon and its identity.
    def peer_home
      unless @world.peer_daemon
        home = Dir.mktmpdir("rho-named-agents-peer-e2e")
        root = Dir.mktmpdir("rho-named-agents-peer-root")
        daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, env: { "RHO_WORKSPACE" => @room }, tools_root: root)
        @world.peer_home = home
        @world.peer_root = root
        @world.peer_daemon = daemon
        daemon.start
        E2E::Ceremony.confirm(actor: @world.actor, started: daemon.start_ceremony, status: -> { daemon.status })
        adopted = self.class.await_workspace_adopted(daemon)
        assert_equal @room, adopted, "home B adopted the same room under the knob"
      end
      [@world.peer_daemon, *rho_identity(@world.peer_daemon)]
    end

    # ---- the SDK half ----

    def await_child(chat, label:)
      await("no child labelled #{label} under #{chat.public_id}", every: POLL) do
        chat.children.items.find { |row| row.parent&.label == label }
      end
    end

    def await_reply(chat, after:)
      await("no reply settled past position #{after} on #{chat.public_id}", every: POLL) do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # ---- the member plane, as the steward ----

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def loop_path(loop) = "/agent_api/v1/workspaces/#{@room}/agent_loops/#{loop}"

    def loop_row(loop)
      document = agent_api(loop_path(loop))
      document.fetch("agent_loop") { flunk "the loop read was refused: #{document.inspect}" }
    end

    TERMINAL_TASK_STATUSES = %w[completed failed canceled timed_out uncertain skipped].freeze

    # A task's result as the model read it, once the row settled.
    def task_result(loop, task_key)
      task = await("the task #{task_key} of #{loop} never settled", every: POLL) do
        document = agent_api("#{loop_path(loop)}/tasks/#{task_key}")
        row = document.fetch("task") { flunk "the task read was refused: #{document.inspect}" }
        row if TERMINAL_TASK_STATUSES.include?(row["status"])
      end
      task["output"] || Array(task["content"]).map { |block| block["text"] }.compact.join
    end

    # The sealed request of a round: its entries, in wire order.
    def sealed_entries(loop, task_key)
      document = agent_api("#{loop_path(loop)}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
      entries
    end

    def sealed_texts(loop, task_key) = texts_of(sealed_entries(loop, task_key))

    def text_of(entry) = entry.fetch("parts").map { |part| part.fetch("text") }.join

    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.values.flat_map { |item| texts_of(item) }
      else []
      end
    end

    def await_loop_status(loop, status)
      await("the loop #{loop} never reached #{status}", every: POLL) do
        row = loop_row(loop)
        flunk "the loop #{loop} failed: #{row["failure_reason"].inspect}" if row["status"] == "failed" && status != "failed"
        row if row["status"] == status
      end
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{@room}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def await_feed(conversation, message)
      await(message, every: POLL) { yield(feed(conversation)) }
    end

    # Every turn the feed opened on a loop other than `except`, in feed order.
    def new_turns(items, except:)
      items.select do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
          item.dig("payload", "turn_kind") != "compaction_summary" &&
          !except.include?(item.dig("payload", "agent_loop_public_id"))
      end.sort_by { |item| item.fetch("sequence") }
    end

    def await(message, every:)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
