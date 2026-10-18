require "test_helper"
require "fileutils"
require "json"
require "rho"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/peer_program"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# THE ASSEMBLY BYTES: an SDK peer declares `assembly` with a template that names the three slots,
# memory, history and the input in an order that is NOT the built-in one, with one variable; rho
# opens the conversation to it and posts the Owner's words into it; the sealed request of the peer's reply
# is the template's order, merged by the wire rule, byte for byte against a rendering DERIVED here
# from the merge rule (persona, memory and history's user turn are adjacent user segments
# and merge into ONE item, each its own part — nothing folds); `rho prompt preview --to @peer` through `exe/rho` answers the SAME bytes
# before the send and writes nothing; the allocator trims history to nothing before a slot the
# window cannot fund is dropped (`floor_unmet` is evidence, the bytes still send); the negative: the
# same peer under `default` compiles the built-in order and none of the template's text; and THE
# STANDALONE LOOP: rho's daemon authors one under `default` through its `POST /runs` route,
# and round one's sealed request is the seed the kernel compiled at create — rho's own
# `system_prompt` slot and the room's character as one system item, the room's memory under the
# conversation-less header, the Runner environment and rho's input as one user item, no system field on the wire.
#
# WHO IS WHO, so the preview and the send are the same bytes: rho CREATES
# the conversation (`rho do --agent @peer`) and attributes its inputs to
# the stable Owner Speaker. The preview and second send use that same
# Speaker and rho's member authority; the SDK send retains the per-turn
# template variables. The persona slot resolves to the steward's and is
# unwritten — the template places the slot, and it renders nothing. The
# template's texts carry no `!mock` word: the fake reads a
# directive anywhere in its joined input, and an echo is the second
# witness only if it echoes.
#
# ONE CEREMONY PER FILE (the `group_chat` shape): the steward's session,
# the ROOM (an account-wide workspace the daemon adopts under
# `RHO_WORKSPACE`), the daemon and the peer are booted once — three device
# grants. The room is the journey's own and its character with it; the
# peer's `system_prompt` is the peer's own transient profile. A standalone
# Runner is shared by the two Agents; the full-mode Runner remains private to rho. No persona
# is written on any Human. No paid lane: a model's reading of a
# re-ordered prompt is not the property under test.
class AssemblyBytesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 120

  SYSTEM_PROMPT = "Answer as the room's reviewer.".freeze
  CHARACTER = "The room is {{workspace}}.".freeze
  SCENE = "Scene: {{scene}}, with {{agent}}.".freeze
  DEFAULT_SCENE = "an ordinary day".freeze
  TURN_SCENE = "a rainy night".freeze
  NOTE = "gate code 4471".freeze
  OPENING = "Where do we start?".freeze
  FOLLOW_UP = "and so?".freeze
  # The explicit bindings render their catalog even before any note exists.
  MEMORY_HEADER = "Durable database memory through the selected logical paths. " \
                  "It persists across replies and machines.\n" \
                  "Available roots: conversation/ (read and write), speaker/ (read and write), " \
                  "agent/ (read and write), workspace/ (read and write).".freeze
  # The standalone seed uses the kernel's default roots and their ordinary header.
  STANDALONE_MEMORY_HEADER = "Durable memory for this workspace and the person this work answers\n" \
                             "to. It persists across runs and machines. You cannot edit it from here.".freeze
  # The standalone loop's words, and the first sentence of rho's guideline
  # (`Rho::RunDeclaration::GUIDELINE`, its `system_prompt` slot) — read back
  # through `rho prompt show`, never quoted whole here.
  TASK = "List what the room remembers.".freeze
  GUIDELINE_OPENING = "Some tool schemas are available through tool discovery.".freeze
  # The non-default order: the peer's developer-role identity, the room,
  # the scene ahead of the person, memory and history — input last, as
  # the grammar demands; no `lead`/`tail`, so neither the Runner environment
  # nor client lead text is placed.
  TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "slot", "slot" => "character" },
      { "type" => "inline", "role" => "user", "text" => SCENE },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" },
      { "type" => "history" },
      { "type" => "input" },
    ],
    "variables" => { "scene" => DEFAULT_SCENE },
  }.freeze
  TEMPLATE_KEYS = %w[slot:system_prompt slot:character inline:2 slot:persona memory history input].freeze
  DEFAULT_KEYS = %w[slot:system_prompt slot:character slot:persona memory skills history lead tail input].freeze
  # Past `dev/mock-text`'s 8192-token window on its own: the floor the
  # allocator cannot fund, which history must yield to first.
  OVERSIZED = ("The room is enormous. " * 2_000).freeze

  World = Struct.new(:daemon, :home, :project, :steward, :actor, :room_public_id, :room_name,
    :peer, :peer_handle, :peer_display_name, :runner, :shared_runner, :shared_runner_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-assembly-bytes-e2e")
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room_name = "Assembly room #{SecureRandom.hex(3)}"
      room = steward_client.workspaces.create(
        name: room_name, access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).workspace.public_id
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_WORKSPACE" => room })
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor,
        room_public_id: room, room_name: room_name)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      adopted = await_workspace_adopted(daemon)
      raise "the daemon adopted #{adopted} instead of the room #{room}" unless adopted == room

      E2E.enable_dev_lane!
      E2E.hosts.start
      @world.project = File.join(home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
      daemon.control(:post, "/environment", body: { root: @world.project })
      @world.runner = daemon.status.fetch("identity").fetch("runner_executor_public_id")
      grant_shared_runner!(base_url, actor, home)

      peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "assembly-peer")
      peer.declare_configuration(prompt_mechanism: "assembly", prompt_template: TEMPLATE,
        runner_executor_public_ids: [@world.shared_runner_id], runner_tool_names: [],
        prompt_documents: { "system_prompt" => { "content" => SYSTEM_PROMPT, "role" => "developer" } })
      steward_client.workspace(room).prompt_documents.write("character", CHARACTER)
      principals = steward_client.workspace(room).principals
      @world.peer = peer
      @world.peer_handle = principals.find { |row| row.public_id == peer.public_id }&.handle ||
        raise("the peer #{peer.public_id} is not a principal of the room")
      @world.peer_display_name = peer.client.profile.fetch.member.display_name
      @world
    end

    def grant_shared_runner!(base_url, actor, home)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        registration_identifier: "e2e-assembly-runner", runner_display_name: "Assembly environment")
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
      credentials = device.await_credentials(authorization)
      runner_home = File.join(home, "shared-runner").tap { |path| FileUtils.mkdir_p(path) }
      @world.shared_runner = E2E::ExecutorProcess.new(base_url: base_url, home: runner_home,
        credential: credentials.executor_access_token, tools: ["read"], environment: @world.project)
      @world.shared_runner.start
      @world.shared_runner_id = @world.shared_runner.executor_public_id
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

      begin
        world.shared_runner&.stop
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { AssemblyBytesTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @room = @world.room_public_id
    @peer = @world.peer
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  rescue StandardError => error
    warn "Could not capture the assembly bytes E2E logs: #{error.class}: #{error.message}"
  end

  # TURN 1 is rho's opening to the peer: the template's order with the
  # variable's default, memory roots with no notes, no history — three items. Then the
  # steward writes a note; rho PREVIEWS the follow-up with the turn's
  # value through `exe/rho`; rho POSTS the same Speaker's words with the
  # same value; the sealed request of TURN 2 is the derived rendering and
  # the preview's bytes, and the preview wrote nothing. Then the trim
  # order, and the negative under `default`.
  def test_the_template_order_seals_byte_for_byte_and_the_preview_answers_the_same_bytes
    await_rho_ready
    peer_handle = @world.peer_handle
    peer_name = @world.peer_display_name

    # ---- TURN 1: rho opens the conversation to the peer ----
    output, status = @daemon.cli("do", OPENING, "--model", MODEL, "--dir", @world.project,
      "--agent", "@#{peer_handle}", "--runner", @world.shared_runner_id)
    assert_predicate status, :success?, "rho do --agent failed:\n#{output}"
    conversation = output[/^conversation:\s+(\S+)/, 1]
    refute_nil conversation, "rho do printed no conversation id:\n#{output}"
    chat = @conversations.conversation(conversation)
    assert_equal @peer.public_id, chat.fetch.answering_user_public_id, "the peer is the conversation's answerer"
    first = await_reply(chat, after: -1)
    assert_equal @peer.public_id, first.answering_user_public_id
    # The conversation's Speaker root is relative; this execution captured
    # the actual Owner whose words rho submitted.
    speaker = first.active_variant.memory_context.fetch("bindings").find { |binding| binding.fetch("name") == "speaker" }.fetch("speaker_public_id")
    opening_words = owner_words(speaker, OPENING)
    follow_up_words = owner_words(speaker, FOLLOW_UP)

    opening = sealed_request_of(chat, first)
    assert_equal %w[developer system user], opening.entries.map { |entry| role_of(entry) },
      "the peer's developer identity, the room, then ONE user item: the scene, no persona, the memory roots, the words"
    assert_equal SYSTEM_PROMPT, text_of(opening.entries[0])
    assert_equal "The room is #{@world.room_name}.", text_of(opening.entries[1]), "{{workspace}} from the room"
    assert_equal ["Scene: #{DEFAULT_SCENE}, with #{peer_name}.", MEMORY_HEADER, opening_words], parts_of(opening.entries[2]),
      "the template's default value, {{agent}} the answerer's name, the input last — the persona slot renders nothing"
    refute opening.request_options.key?("instructions"), "the assembled lane's system text rides the list"
    assert first.text.start_with?("Mock: "), "the fake echoed: #{first.text.inspect}"
    assert_echoed_in_order(first.text, SYSTEM_PROMPT, "Scene: #{DEFAULT_SCENE}", OPENING)

    # ---- the note, then THE PREVIEW through exe/rho, --to the peer ----
    chat.memory.write("workspace/notes.md", NOTE, expected_public_id: nil, expected_lock_version: nil)
    documents = chat.memory.list
    assert_equal ["workspace/notes.md"], documents.map(&:path),
      "this room's memory is the note alone — another lane's residue would change the pinned bytes"
    turns_before = chat.turns.list.items.length
    preview = rho_preview(conversation, to: peer_handle, prompt: FOLLOW_UP, var: "scene=#{TURN_SCENE}")
    assert_equal turns_before, chat.turns.list.items.length, "a preview opens no turn"
    assert_empty chat.inputs.list.items, "a preview queues no input"
    assert_equal "assembly", preview.fetch("mechanism")
    assert_equal TEMPLATE_KEYS, preview.fetch("blocks").map { |block| block["block"] }, "the evidence follows the template"
    assert_equal({ "included" => 1, "omitted" => 0 }, preview.fetch("memory"))
    assert_equal({ "system_prompt" => 1, "character" => 1 }, preview.fetch("slots"),
      "the registered documents compiled, by slot — the unwritten persona is absent")
    assert_equal true, preview.dig("storage", "within_bound")
    assert_equal %w[selected selected selected empty selected selected selected],
      preview.fetch("blocks").map { |block| block["state"] }, "the empty persona slot is a block, never an item"

    # ---- TURN 2: rho posts the same Speaker's words with the same value ----
    rho_chat = rho_member_client.workspace(@room).conversation(conversation)
    rho_chat.inputs.create(
      kind: "direct_reply", model: MODEL, text: FOLLOW_UP, to: @peer.public_id,
      speaker_public_id: speaker, variables: { "scene" => TURN_SCENE }, idempotency_key: SecureRandom.uuid)
    second = await_reply(chat, after: first.position)
    sealed = sealed_request_of(chat, second)

    # THE PINNED RENDERING, derived from the merge rule: the scene inline,
    # the (unwritten) persona, memory and history's user turn are adjacent
    # user segments — ONE item, each its own part; the assistant turn
    # stands alone; input last.
    memory_block = "#{MEMORY_HEADER}\n\n## workspace/notes.md\n#{NOTE}"
    expected = [
      ["developer", [SYSTEM_PROMPT]],
      ["system", ["The room is #{@world.room_name}."]],
      ["user", ["Scene: #{TURN_SCENE}, with #{peer_name}.", memory_block, opening_words]],
      ["assistant", [first.text]],
      ["user", [follow_up_words]],
    ]
    assert_equal expected, sealed.entries.map { |entry| [role_of(entry), parts_of(entry)] },
      "the template's order, merged by the wire rule, the turn's value over the default"
    assert_equal preview.fetch("entries"), sealed.entries,
      "THE SAME BYTES: the preview rho took before the send is the request the send sealed, entry for entry"
    assert_echoed_in_order(second.text, "Scene: #{TURN_SCENE}", NOTE, OPENING, FOLLOW_UP)

    # ---- HISTORY YIELDS BEFORE THE SLOTS ----
    # An oversized character for one estimate: the allocator gives history
    # nothing and the floor it cannot fund is EVIDENCE — the bytes render
    # whole and the count says what the window gate would refuse.
    trimmed = rho_chat.estimate_input(
      model: MODEL, prompt: FOLLOW_UP, render: true, to: @peer.public_id, speaker_public_id: speaker,
      inline: [{ "slot" => "character", "text" => OVERSIZED }]
    )
    blocks = trimmed.rendered.blocks.to_h { |block| [block.block, block] }
    assert_predicate blocks.fetch("slot:character"), :floor_unmet?, "the window cannot fund the room"
    assert_predicate blocks.fetch("history"), :empty?, "history yielded first"
    assert_equal 0, blocks.fetch("history").allocated_tokens
    assert_equal 0, trimmed.history.selected
    assert_equal "budget_exceeded", trimmed.history.skipped_reason
    assert_equal OVERSIZED, text_of(trimmed.rendered.entries[1]),
      "the slot still renders whole: exclusion is evidence, never a byte change"
    assert_operator trimmed.input_tokens, :>, trimmed.catalog_input_token_limit,
      "the count says what the drain's window gate will refuse"
    assert_equal({}, trimmed.rendered.slots.slice("character"), "an override carries no version")

    # ---- THE NEGATIVE: the same peer under `default` ----
    @peer.declare_configuration(prompt_mechanism: "default", prompt_template: TEMPLATE,
      runner_executor_public_ids: [@world.shared_runner_id], runner_tool_names: [],
      prompt_documents: { "system_prompt" => { "content" => SYSTEM_PROMPT, "role" => "developer" } })
    environment_lead = runner_environment_lead(@world.shared_runner_id)
    defaulted = rho_chat.estimate_input(
      model: MODEL, prompt: FOLLOW_UP, render: true, to: @peer.public_id, speaker_public_id: speaker
    )
    assert_equal "default", defaulted.rendered.mechanism
    assert_equal DEFAULT_KEYS, defaulted.rendered.blocks.map(&:block), "the built-in order; the stored template unread"
    texts = defaulted.rendered.entries.map { |entry| text_of(entry) }
    # The two assistant turns are the fake's echoes of the ASSEMBLED turns
    # and carry the scene as history's verbatim words; the compiled entries
    # (every non-echo) carry none of the template's text.
    compiled = texts - [first.text, second.text]
    refute compiled.any? { |text| text.include?("Scene:") }, "none of the template's text: #{compiled.inspect}"
    # The default assembly order: identity, the room, then persona (none) + memory + history's first
    # user turn as ONE item, each its own part; history now holds both turns.
    # Its lead places the selected Runner's public announcement before the input.
    assert_equal %w[developer system user assistant user assistant user],
      defaulted.rendered.entries.map { |entry| role_of(entry) }
    assert_equal [[SYSTEM_PROMPT], ["The room is #{@world.room_name}."], [memory_block, opening_words], [first.text],
                  [follow_up_words], [second.text], [environment_lead, follow_up_words]],
      defaulted.rendered.entries.map { |entry| parts_of(entry) }
    assert_equal({ "system_prompt" => 2, "character" => 1 }, defaulted.rendered.slots,
      "the full Profile declaration rewrote its system prompt; the room's character was not rewritten")

    # ---- THE STANDALONE LOOP under `default`: rho's own seed ----
    # The daemon's `POST /runs` author route carries the shell's word to
    # the kernel; the seed is compiled ONCE at create over the room — no
    # conversation, no history, memory frozen — and round one sends it
    # as sealed. The creator is rho's profile: its `system_prompt` slot
    # (the guideline the daemon writes at every declare edge) leads, the
    # room's character behind it in the same system item; the persona is
    # the steward's, unwritten; the memory is the one note under the
    # conversation-less header; the Runner's announcement is a lead part;
    # rho's own instructions ride ahead of the words in the input block
    # (the shell admits no inline); nothing rides the wire's system field.
    guideline = rho_slot("system_prompt", opening: GUIDELINE_OPENING)
    environment_lead = runner_environment_lead(@world.runner)
    started = @daemon.control(:post, "/runs",
      body: { prompt: TASK, model: MODEL, working_directory: @world.project, prompt_mechanism: "default" })
    loop_id = started.dig("run", "public_id")
    refute_nil loop_id, "rho answered #{started.inspect}"
    loops = @client.workspace(@room).runs
    completed = await("the standalone loop never completed") do
      row = loops.fetch(loop_id)
      flunk "the standalone loop failed: #{row.failure_reason.inspect}" if row.status == "failed"
      row if row.status == "completed"
    end
    assert_equal "default", completed.prompt_mechanism, "the shell's word on the row"
    seed = loops.run(loop_id).tasks_context("work").request
    assert_equal %w[system user], seed.entries.map { |entry| role_of(entry) },
      "the guideline and the room as ONE system item; memory, the lead and the words as ONE user item"
    assert_equal [guideline, "The room is #{@world.room_name}."], parts_of(seed.entries[0]),
      "rho's own system_prompt slot leads, the room's character behind it — no persona is written"
    user_parts = parts_of(seed.entries[1])
    assert_equal 3, user_parts.length, "memory, environment lead, then the input block, each its own part: #{user_parts.inspect}"
    memory, environment, words = user_parts
    assert_equal "#{STANDALONE_MEMORY_HEADER}\n\n## workspace/notes.md\n#{NOTE}", memory,
      "the room's memory under the conversation-less header, its own part"
    assert_equal environment_lead, environment, "the selected Runner's public announcement renders in the lead block"
    assert_includes environment, "Relative paths resolve against #{@world.project}.", "the Runner states its root"
    assert_includes words, "Conversation kind: standalone.", "the explicit default shell carries its known kind in the input"
    assert words.end_with?("\n\n#{TASK}"), "the words last: #{words.inspect}"
    refute seed.request_options.key?("instructions"), "no system field under an assembled word"
    answer = loops.run(loop_id).task("work").output.to_s
    assert_echoed_in_order(answer, GUIDELINE_OPENING, "The room is #{@world.room_name}.", NOTE, TASK)
  ensure
    @peer&.declare_configuration(prompt_mechanism: "assembly", prompt_template: TEMPLATE,
      runner_executor_public_ids: [@world.shared_runner_id], runner_tool_names: [],
      prompt_documents: { "system_prompt" => { "content" => SYSTEM_PROMPT, "role" => "developer" } })
  end

  private

    def owner_words(speaker, text) = "<message from=\"Owner\" kind=\"ingress\" speaker=\"#{speaker}\">\n#{text}\n</message>"

    def rho_member_client = @daemon.member_client

    def runner_environment_lead(runner)
      announcement = rho_member_client.executors.show(runner).environment
      fragments = announcement.fetch("fragments").map { |fragment| fragment.fetch("text") }
      ["Work environment: Runner #{runner}.", *fragments].join("\n\n")
    end

    # `rho prompt preview --json` through the shipped binary: the document
    # whole, parsed past whatever the runtime prints ahead of it.
    def rho_preview(conversation, to:, prompt:, var:)
      output, status = @daemon.cli("prompt", "preview", conversation, "--model", MODEL, "--prompt", prompt,
        "--to", "@#{to}", "--var", var, "--json")
      assert_predicate status, :success?, "rho prompt preview failed:\n#{output}"
      opening = output.index("{")
      refute_nil opening, "rho prompt preview printed no JSON:\n#{output}"
      JSON.parse(output[opening..])
    end

    # `rho prompt show SLOT` through the shipped binary: the slot's content
    # from its known opening, past whatever the runtime prints ahead of it.
    def rho_slot(slot, opening:)
      output, status = @daemon.cli("prompt", "show", slot)
      assert_predicate status, :success?, "rho prompt show failed:\n#{output}"
      start = output.index(opening)
      refute_nil start, "rho prompt show printed no #{slot}:\n#{output}"
      output[start..].strip
    end

    # rho's runner announced and its profile declared: the daemon is ready
    # to post as itself.
    def await_rho_ready
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
      @daemon.await("rho never declared its profile") do
        @daemon.log_lines.find { |line| line["event"] == "profile.declared" }
      end
    end

    def await_reply(chat, after:)
      await("no reply settled past position #{after} on #{chat.public_id}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # THE DEBUG DOOR: the active candidate's sealed request, off the deck.
    def sealed_request_of(chat, turn)
      deck = chat.turns.variants(turn.public_id)
      chat.turns.request(turn.public_id, deck.active.public_id)
    end

    # THE ECHO AGREES — the second witness: the fake joins its whole input,
    # so what a turn was shown reads off its answer in the same order.
    def assert_echoed_in_order(echo, *needles)
      positions = needles.map { |needle| echo.index(needle) || flunk("#{needle.inspect} never reached the model: #{echo.inspect}") }
      assert_equal positions, positions.sort, "the echo carries the template's order: #{echo.inspect}"
    end

    def role_of(entry) = entry.fetch("role")

    def text_of(entry)
      entry.fetch("parts").map { |part| part.fetch("text") }.join
    end

    # A merged message's texts, each its own part: the wire merges
    # adjacent same-role blocks, and nothing folds them.
    def parts_of(entry) = entry.fetch("parts").map { |part| part.fetch("text") }

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
