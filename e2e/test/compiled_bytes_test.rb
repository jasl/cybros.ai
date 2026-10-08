require "test_helper"
require "securerandom"
require "support/actor_provisioning"

# THE COMPILED BYTES: a character on the workspace and a persona on the person land in slot order
# ahead of memory as the first system-role item of the sealed list; an inline `slot` entry replaces
# one for a turn and the row stands; `raw` seals the entries as sent, byte for byte; and the
# inspection read answers exactly what was sealed — read through the kernel's own door, never the
# mock's echo alone (the echo is the second witness).
#
# WHAT THIS PROVES THAT NOTHING ELSE DOES: the two prompt-document doors,
# the assembler's slot order and the debug door against the real wire, top
# to bottom — a slot written over HTTP by one caller compiles into a
# request another process sealed, and the read returns those bytes. No
# daemon, no browser: a Human's member token, a fresh workspace, the mock
# provider. A model's prompt-format projection is observed separately at
# the fake provider, then regeneration on another model proves the original
# roles remain available through the same public request read. Independent
# reasoning enablement is resolved against the selected model's support and
# reaches that same wire without replacing the selected effort.
#
# WHAT IT LEAVES BEHIND IS ANOTHER LANE'S PROMPT: the world's Humans are
# shared by every journey, and a persona on `shared_human` would ride into
# every later turn that person posts (memory_scopes' residue discipline).
# Teardown takes it back, and this journey runs in a world with no
# shared_human reader (E2E::JourneyGroups).
class CompiledBytesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  TURN_TIMEOUT = 60
  # 120 requests a minute per identity, and a journey that polls faster
  # than that gets 429s of its own making.
  POLL = 1.0

  CHARACTER = "You are the room's narrator in {{workspace}}.".freeze
  PERSONA = "The person is {{user}}.".freeze
  NOTE = "gate code 4471".freeze
  OVERRIDE = "For this turn only: you are terse.".freeze
  MEMORY_HEADER = "Durable memory".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "Compiled bytes #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    @workspace_context = @client.workspace(@workspace.public_id)
    @conversations = @workspace_context.conversations
    @profile = @client.profile
  end

  def teardown
    # The persona is the shared Human's and outlives this workspace; the
    # character is the workspace's own, taken back so a re-run reads the
    # world fresh either way.
    [[@profile, "persona"], [@workspace_context, "character"]].each do |context, slot|
      context&.prompt_documents&.delete(slot)
    rescue CybrosAgent::Api::NotFound
      nil
    rescue StandardError => error
      warn "Could not delete the #{slot} slot after the compiled-bytes lane: #{error.class}: #{error.message}"
    end
  end

  def test_the_slots_lead_the_sealed_list_and_the_read_answers_exactly_what_was_sealed
    chat = @conversations.conversation(
      @conversations.create(title: "Compiled bytes", idempotency_key: SecureRandom.uuid).public_id
    )

    # ---- 1. THE SLOTS: identity, the room, the person — then memory ----
    character = @workspace_context.prompt_documents.write("character", CHARACTER)
    assert_equal "character", character.slot
    assert_equal 1, character.version, "a fresh workspace's first write"
    assert_equal "system", character.role, "the kernel's default role"
    persona = @profile.prompt_documents.write("persona", PERSONA)
    assert_equal "persona", persona.slot
    chat.memory.write("workspace/notes.md", NOTE, expected_public_id: nil, expected_lock_version: nil)

    first = ask(chat, "first")
    sealed = sealed_request_of(chat, first)
    assert_equal %i[entries request_options], sealed.to_h.keys, "the read is exactly the two keys"

    # THE FIRST ITEM IS THE SLOTS, one system item: the character then the
    # persona, macros substituted from their named sources, merged by the
    # wire rule that merges adjacent same-role blocks — each its own part.
    expected_slots = ["You are the room's narrator in #{@workspace.name}.", "The person is #{@actor.display_name}."]
    assert_equal "system", role_of(sealed.entries.first)
    assert_equal expected_slots, parts_of(sealed.entries.first)
    assert_equal 1, sealed.entries.count { |entry| role_of(entry) == "system" },
      "every system-role slot merged into ONE leading item"

    # THEN MEMORY, a user item that opens with the block's header and
    # carries the note ahead of the prompt (both user-role, so merged: the
    # memory block one part, the prompt the next).
    assert_equal "user", role_of(sealed.entries[1])
    memory_part, prompt_part = parts_of(sealed.entries[1])
    assert memory_part.start_with?(MEMORY_HEADER), "memory follows the slots: #{memory_part.inspect}"
    assert_includes memory_part, "## workspace/notes.md"
    assert_includes memory_part, NOTE
    assert_equal "first", prompt_part, "the note rides ahead of the prompt, which is the next part"
    refute sealed.request_options.key?("instructions"),
      "the assembled lane's system text rides the list, never the wire's system field"

    # THE ECHO AGREES — the second witness: the mock joins its whole input,
    # so the reply's text carries the same order.
    echo = first.text
    assert echo.start_with?("Mock: ")
    ordered = [*expected_slots, MEMORY_HEADER, NOTE, "first"]
    positions = ordered.map { |needle| echo.index(needle) || flunk("#{needle.inspect} never reached the model: #{echo.inspect}") }
    assert_equal positions, positions.sort, "character, persona, memory, prompt — in that order: #{echo.inspect}"

    # ---- 2. THE OVERRIDE: one turn's character, the row untouched ----
    second = ask(chat, "second", inline: [{ "slot" => "character", "text" => OVERRIDE }])
    overridden = sealed_request_of(chat, second)
    assert_equal "system", role_of(overridden.entries.first)
    assert_equal [OVERRIDE, "The person is #{@actor.display_name}."], parts_of(overridden.entries.first),
      "the inline entry replaced the character in slot order; the persona still stands"
    standing = @workspace_context.prompt_documents.read("character")
    assert_equal CHARACTER, standing.content, "the registered row is untouched by a per-turn override"
    assert_equal 1, standing.version

    refused = assert_raises(CybrosAgent::Api::InvalidRequest) do
      chat.inputs.create(
        kind: "direct_reply", model: MODEL, text: "x",
        inline: [{ "slot" => "character", "position" => "lead", "text" => "x" }],
        idempotency_key: SecureRandom.uuid
      )
    end
    assert_equal "parameter_invalid", refused.code, "slot and position never together"

    # ---- 3. RAW, BYTE-IDENTICAL: no slots, no memory, no history ----
    token = SecureRandom.hex(4)
    entries = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "raw #{token}" }] }]
    third = ask(chat, nil, context_mode: "raw", entries: entries, instructions: "Be brief.")
    raw = sealed_request_of(chat, third)
    assert_equal entries, raw.entries, "raw seals the caller's entries as sent, byte for byte"
    assert_equal "Be brief.", raw.request_options.fetch("instructions"),
      "under raw the caller's instructions IS the wire's system field"
    assert_includes third.text, "raw #{token}"
    refute_includes third.text, "narrator", "no character under raw"
    refute_includes third.text, NOTE, "no memory under raw"

    # ---- 4. THE ESTIMATE funds the override like the send does ----
    bare = chat.estimate_input(model: MODEL, prompt: "x")
    with_override = chat.estimate_input(
      model: MODEL, prompt: "x", inline: [{ "slot" => "character", "text" => "#{OVERRIDE} #{"and more " * 40}" }]
    )
    assert_operator with_override.input_tokens, :>, bare.input_tokens,
      "an inline slot entry is priced in the estimate as it is in the send"
  end

  def test_model_prompt_format_changes_the_wire_without_following_raw_input_into_another_model
    chat = @conversations.conversation(
      @conversations.create(title: "Model prompt format", idempotency_key: SecureRandom.uuid).public_id
    )
    entries = [
      ["system", "Root policy."],
      ["developer", "Initial environment."],
      ["user", "First question."],
      ["assistant", "First answer."],
      ["system", "Updated policy."],
      ["developer", "Updated environment."],
      ["user", "!mock echo=request -- Final question."],
    ].map { |role, text| { "role" => role, "parts" => [{ "type" => "text", "text" => text }] } }
    instructions = "Keep every message in its original order."
    first = ask(chat, nil, model: E2E::CatalogOverlay::PROMPT_FORMAT_MODEL,
      context_mode: "raw", entries: entries, instructions: instructions, tool_names: [])
    source = sealed_request_of(chat, first)
    assert_equal entries, source.entries, "the stored request retains every original role and text"
    assert_equal instructions, source.request_options.fetch("instructions")

    projected = JSON.parse(first.text.delete_prefix("Mock: "))
    refute projected.key?("instructions"), "the separate instruction field joined the leading system message once"
    assert_equal %w[system user assistant user user user], projected.fetch("input").map { |item| item.fetch("role") }
    assert_equal [
      [instructions, "Root policy.", "Initial environment."].join("\n\n"),
      *entries.drop(2).map { |entry| parts_of(entry).join },
    ], projected.fetch("input").map { |item| wire_text(item) }

    regenerated = chat.turns.regenerate(first.public_id, model: MODEL, idempotency_key: SecureRandom.uuid)
    candidate = await("the unadapted model's regenerated reply") do
      row = chat.turns.variants(first.public_id).items.find { |variant| variant.public_id == regenerated.variant.public_id }
      flunk("regeneration ended #{row.status}") if row && %w[failed canceled].include?(row.status)
      row if row&.status == "completed"
    end
    original_wire = JSON.parse(candidate.content.delete_prefix("Mock: "))
    assert_equal instructions, original_wire.fetch("instructions")
    assert_equal entries.map { |entry| role_of(entry) }, original_wire.fetch("input").map { |item| item.fetch("role") }
    assert_equal entries.map { |entry| parts_of(entry).join }, original_wire.fetch("input").map { |item| wire_text(item) }
    assert_equal entries, chat.turns.request(first.public_id, candidate.public_id).entries
    assert_equal source.to_h, chat.turns.request(first.public_id, first.active_variant.public_id).to_h,
      "sending either model leaves the original candidate's canonical request untouched"
  end

  def test_reasoning_enabled_false_reaches_a_disable_supported_model_without_losing_effort
    assert_reasoning_off_request(
      model: E2E::CatalogOverlay::REASONING_SWITCH_MODEL, effective_enabled: false,
      wire_reasoning: { "effort" => "none" }
    )
  end

  def test_reasoning_enabled_false_is_ignored_when_the_model_always_reasons
    assert_reasoning_off_request(model: MODEL, effective_enabled: true,
      wire_reasoning: { "effort" => "high", "summary" => "auto" })
  end

  private

    def assert_reasoning_off_request(model:, effective_enabled:, wire_reasoning:)
      chat = @conversations.conversation(
        @conversations.create(title: "Independent reasoning control", idempotency_key: SecureRandom.uuid).public_id
      )
      entries = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "!mock echo=request -- reasoning control" }] }]
      turn = ask(chat, nil, model: model, reasoning_enabled: false, reasoning_effort: "high",
        context_mode: "raw", entries: entries, tool_names: [])

      assert_equal effective_enabled, turn.active_variant.model.reasoning_enabled,
        "the public variant reports the selected model's effective enablement"
      assert_equal "high", turn.active_variant.model.reasoning_effort,
        "the intensity selection survives an independent off request"
      sealed = sealed_request_of(chat, turn)
      assert_equal entries, sealed.entries

      wire = JSON.parse(turn.text.delete_prefix("Mock: "))
      assert_equal wire_reasoning, wire.fetch("reasoning"),
        "the fake provider received the resolved native control"
    end

    # One `direct_reply` and its settled reply — the first completed
    # `direct_reply` past the positions already on the timeline.
    def ask(chat, text, model: MODEL, **fields)
      after = chat.turns.list.items.map(&:position).max || -1
      fields = fields.merge(text: text) unless text.nil?
      chat.inputs.create(kind: "direct_reply", model: model, idempotency_key: SecureRandom.uuid, **fields)
      await("a reply to #{(text || fields[:entries]).inspect}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.kind == "direct_reply" }
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

    def role_of(entry) = entry.fetch("role")

    # A merged message's texts, each its own part: the wire merges adjacent
    # same-role blocks, and nothing folds them.
    def parts_of(entry) = entry.fetch("parts").map { |part| part.fetch("text") }

    def wire_text(item) = item.fetch("content").map { |part| part.fetch("text") }.join

    # A 429 IS A BUG IN THIS HARNESS, not weather to be waited out.
    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        result = begin
          yield
        rescue CybrosAgent::Api::RateLimited => throttle
          flunk("the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s)")
        end
        return result if result
        flunk("the deployment never reached #{what}") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end
end
