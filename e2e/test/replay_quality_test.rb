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
# on the configured model alone (`error_model=`), and the answering profile's ordered
# fallback list re-asks the reply on its permitted alternative. Each request's cache kind
# is a sealed fact (`request_options.prompt_cache`).
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
      compaction_policy: nil, default_model: MODEL, fallback_models: [FALLBACK]
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
    assert_equal [FALLBACK], fallback.fallback_models
    assert_equal "explicit", fallback.model_selection.fetch("source")
    assert_equal [FALLBACK], fallback.model_selection.fetch("alternatives")
    change = @chat.events.items.filter_map { |event| event.payload["model_change"] if event.type == "turn_status" }.last
    assert_equal({ "from" => MODEL, "to" => FALLBACK, "reason" => "provider_overloaded" }, change)
    [overloaded, fallback].each do |variant|
      kind = @chat.turns.request(turn.public_id, variant.public_id).request_options.dig("prompt_cache", "kind")
      assert_equal "mainline", kind, "a conversation's reply is its mainline"
    end
  end

  private

    def reply!(text)
      @chat.inputs.create(kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid,
        model_selection: { source: "explicit", model: MODEL, constraint: "route", alternatives: [FALLBACK] })
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
