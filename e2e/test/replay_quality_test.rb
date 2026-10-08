require "test_helper"
require "cgi/escape"
require "securerandom"
require "support/actor_provisioning"
require "support/peer_program"
require "support/steward_session"

# THE REPLAY-QUALITY RULES, OVER THE WIRE, on the mock lane.
#
# Reasoning is history: every turn's reasoning rides every later request and leaves the window
# only with its turn, so a conversation whose turns and reasoning outgrow the dev row's window arms
# the timeline compaction — a `compaction_summary` turn, the head draining behind it — instead of a
# request re-sent without its traces. The mock's `reasoning=` round now answers as a stateless
# Responses provider does (an encrypted reasoning item, its tokens counted), so the fit prices the
# replayed items as the kernel does for a real provider.
#
# An overload on every attempt is the second trigger of the declared fallback: the mock answers 529
# on the configured model alone (`error_model=`), and the answering profile's `fallback_model`
# re-asks the reply once. Each request's cache kind is a sealed fact (`request_options.prompt_cache`).
class ReplayQualityTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  FALLBACK = "dev/mock-unmetered".freeze
  POLL = 0.5
  PATIENCE = 180

  World = Data.define(:client, :workspace)

  class << self
    def world
      @world ||= begin
        base_url = E2E.base_url
        steward = E2E::ActorProvisioning.world(base_url).rho_steward
        actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
        E2E.enable_dev_lane!
        E2E.hosts.start
        peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "replay-quality")
        workspace = peer.client.workspaces.create(
          name: "Replay quality #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
        ).workspace
        World.new(client: peer.client, workspace: peer.client.workspace(workspace.public_id))
      end
    end
  end

  def setup
    @client = self.class.world.client
    @workspace = self.class.world.workspace
    # A tool-less answerer: every reply is a direct one, and its fallback is declared.
    @client.profile.declare_configuration(
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
      compaction_policy: nil, default_model: nil, fallback_model: FALLBACK
    )
    created = @workspace.conversations.create(idempotency_key: SecureRandom.uuid)
    @chat = @workspace.conversation(created.public_id)
  end

  def teardown
    @chat&.cancel unless passed?
  rescue CybrosAgent::Api::Conflict
    # A failed assertion may follow a settled conversation, which has nothing left to cancel.
    nil
  end

  # The words are short and the thinking long, so it is the REASONING that crosses the fit: each
  # turn's words (its escaped thought rides its own `!mock` line, ~1.8k tokens at the dev row's
  # bytes/4) and its ~1.75k tokens of reasoning fit the dev row's 8,192-token window, answer room
  # and all, for two turns; the third's history — the two earlier turns' words, ~3.8k, fitting on
  # their own — crosses it only with their reasoning priced beside them (~7.3k against ~5.4k). So it
  # waits behind the timeline's summary and then answers, and no request is re-sent without its
  # traces. A kernel that priced traces into leftover room instead would send that third request
  # with the traces dropped and arm nothing.
  def test_turns_and_reasoning_past_the_fit_arm_the_summary_and_the_head_answers_behind_it
    marks = nexus_log_marks
    thought = CGI.escape("weigh it #{"carefully " * 700}")
    3.times do |index|
      reply!("!mock reasoning=#{thought} -- turn #{index} #{"words " * 30}")
      await("turn #{index} never settled") { settled_replies.length > index }
    end

    turns = @chat.turns.list.items
    summary = turns.index { |turn| turn.kind == "compaction_summary" }
    refute_nil summary, "the fit wall arms the timeline compaction: #{turns.map(&:kind).inspect}"
    assert_equal "completed", turns[summary].status
    assert_operator summary, :<, turns.rindex { |turn| turn.kind == "direct_reply" },
      "the third reply ran behind the summary"
    assert_equal "completed", turns.last.status
    refute_match(/event=reasoning_replay_dropped/, nexus_log_since(marks),
      "no request re-sent without its traces")
  end

  # The configured model answers 529 on every attempt; the fallback answers. The reply's first
  # sample stays failed in the deck, the fallback candidate renders, and both requests were sealed
  # as the conversation's mainline.
  def test_an_overloaded_reply_re_asks_once_on_the_declared_fallback
    reply!("!mock error=529 error_model=mock-text -- say hi")
    turn = await("the reply never settled on the fallback") do
      last = @chat.turns.list.items.last
      last if last&.kind == "direct_reply" && last.status == "completed"
    end

    deck = @chat.turns.variants(turn.public_id).items
    overloaded, fallback = deck
    assert_equal %w[failed completed], [overloaded.status, fallback.status]
    assert_equal FALLBACK, "#{fallback.model.provider_id}/#{fallback.model.model_ref}"
    assert_equal "fallback", fallback.source
    change = @chat.events.items.filter_map { |event| event.payload["model_change"] if event.type == "turn_status" }.last
    assert_equal({ "from" => MODEL, "to" => FALLBACK, "reason" => "provider_overloaded" }, change)
    [overloaded, fallback].each do |variant|
      kind = @chat.turns.request(turn.public_id, variant.public_id).request_options.dig("prompt_cache", "kind")
      assert_equal "mainline", kind, "a conversation's reply is its mainline"
    end
  end

  private

    def reply!(text)
      @chat.inputs.create(kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid)
    end

    # The world's Rails logs — the web's and each host's — and where each ends now, so a journey
    # reads only the lines it caused.
    def nexus_log_marks
      [E2E.handle.fetch("env").fetch("RAILS_LOG_FILE"), E2E.hosts.rails_log_path(:jobs),
       E2E.hosts.rails_log_path(:runner)].to_h { |path| [path, File.file?(path) ? File.size(path) : 0] }
    end

    def nexus_log_since(marks)
      marks.sum("") do |path, from|
        File.file?(path) ? File.open(path, encoding: Encoding::UTF_8) { |file| file.seek(from) && file.read } : ""
      end
    end

    def settled_replies
      @chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATIENCE
      loop do
        found = yield
        return found if found
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end
end
