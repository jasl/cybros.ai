require "test_helper"
require "json"
require "net/http"
require "securerandom"
require "stringio"
require "support/actor_provisioning"
require "support/red_square_png"
require "support/live_journey"
require "support/evals/report_line"
require "support/evals/sealed_request"

# A PICTURE A REAL MODEL CAN SEE. A 24×24 PNG — a red square on white, drawn in pure Ruby (Zlib and
# CRC chunks, alt's vision smoke's shape: the e2e bundle carries no vips and no fixture bytes) — is
# staged through the member plane and rides an input beside the words on the catalog's VISION row.
# Turn 1 asks the COLOUR (one word); turn 2, with NO attachment, asks the SHAPE — an answer absent
# from turn 1's reply, so only a picture carried natively in the history can answer it: the stated
# property, "a later turn sees the attachment", on a real engine.
#
# Select an image-input model explicitly with `E2E_VISION_MODEL`; the configured
# text evaluation roster need not support images. No rho, no browser: a Human's member token, a fresh
# workspace, two turns. Paid, local, opt-in: E2E_LIVE=1. Cents per run.
class LiveVisionTest < Minitest::Test
  MODEL = ENV.fetch("E2E_VISION_MODEL", "").freeze
  # One model call per turn with no tools; a paid reply settles in
  # seconds, and a stall must fail here with the hosts' logs dumped.
  TURN_TIMEOUT = 300
  POLL = 3

  def setup
    skip "set E2E_VISION_MODEL to a model with image input" if MODEL.empty?
    skip "live journeys are opt-in (E2E_LIVE=1)" unless ENV["E2E_LIVE"] == "1"
    @provider = E2E::ProviderLanes.provider_of(MODEL)
    key_name = E2E::ProviderLanes.key_name_for(MODEL)
    skip "no e2e lane is configured for provider #{@provider.inspect}" if key_name.nil?
    skip "#{key_name} is not set" if ENV[key_name].to_s.empty?

    @base_url = E2E.base_url
    @human = E2E::ActorProvisioning.world(@base_url).shared_human
    # A PAID LANE NEEDS A PRICED ACCOUNT and an open lane (`LiveJourney`'s
    # `connect_and_open_lane!`, without the daemon it also brings up).
    E2E.operator.set_cost_unit!("USD")
    E2E.operator.enable_provider!(@provider, ENV.fetch(key_name))
    E2E.hosts.start
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @human.member_token)
    @workspace = @client.workspaces.create(
      name: "Vision live #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @conversations = @client.workspace(@workspace.public_id).conversations
  end

  def teardown
    return if passed? || skipped?

    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  end

  def test_a_real_model_names_the_colour_and_a_later_turn_names_the_shape_from_history
    picture = @client.uploads.create_io(StringIO.new(red_square_png), filename: "square.png")
    assert_equal "image/png", picture.content_type, "the bytes decide the type"
    chat = @conversations.conversation(
      @conversations.create(title: "Vision", idempotency_key: SecureRandom.uuid).public_id
    )

    # TURN 1: the colour, with the picture. The question names no shape.
    first = ask(chat, "What colour is the shape in the middle of this picture? Answer with one word.",
      attachments: [picture.public_id])
    assert_match(/\bred\b/i, first.text.to_s, "the model did not see the red square: #{first.text.inspect}")
    sealed = sealed_request_of(chat, first)
    assert_equal [picture.public_id], upload_ids(sealed.entries), "the request sealed the picture natively"

    # TURN 2, NO ATTACHMENT: the shape. Turn 1's reply never said it, so
    # the answer can only come from the picture carried in the history.
    second = ask(chat, "What shape was it? Answer with one word.")
    assert_match(/\b(?:square|rectangle)\b/i, second.text.to_s,
      "the later turn did not see the picture in its history: #{second.text.inspect}")
    later = sealed_request_of(chat, second)
    assert_equal [picture.public_id], upload_ids(later.entries), "turn 2's history seed carried the picture natively"
    report(chat, first, second)
    report_line(first, sealed, 1)
    report_line(second, later, 2)
  end

  private

    # The pure-Ruby red square (`E2E::RedSquarePng`): no library draws it,
    # no fixture bytes are stored.
    def red_square_png = E2E::RedSquarePng.bytes

    # The door, raw: `attachments` beside `text` under `input`. Answers the settled reply turn; a
    # failed one fails HERE with its row, never as a timeout later.
    def ask(chat, text, attachments: nil)
      after = chat.turns.list.items.map(&:position).max || -1
      body, status = post_input(chat, { "kind" => "direct_reply", "text" => text, "model" => { "model" => MODEL },
                                        "attachments" => attachments }.compact)
      assert_equal 202, status, "the input door refused: #{body.inspect}"
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        settled = newer.find { |turn| turn.status == "completed" }
        return settled if settled
        raise "the reply to #{text.inspect} never settled" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep POLL
      end
    end

    def post_input(chat, input)
      uri = URI.join(@base_url, "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations/#{chat.public_id}/inputs")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@human.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate("input" => input)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      [JSON.parse(response.body.to_s.empty? ? "{}" : response.body.force_encoding(Encoding::UTF_8)), response.code.to_i]
    end

    def sealed_request_of(chat, turn)
      deck = chat.turns.variants(turn.public_id)
      chat.turns.request(turn.public_id, deck.active.public_id)
    end

    # the one report line every paid lane prints, through the evals reader (`ReportLine.lane`) off
    # what this lane holds — the turn (one model call, no tools: an inference variant backs no loop,
    # so the row is the turn's) and the sealed request the deck served, whose entries are the line's
    # bytes; the spend is not read here (`—`).
    def report_line(turn, sealed, run)
      row = { "public_id" => turn.public_id, "status" => turn.status,
              "tasks" => [{ "key" => "r1", "kind" => "model_task", "status" => turn.status }] }
      document = { "task_key" => "r1", "entries" => sealed.entries, "request_options" => Hash(sealed.request_options) }
      puts E2E::Evals::ReportLine.render(E2E::Evals::ReportLine.lane(task: "vision", model: MODEL, row: row,
        sealed: document, run: run, reached: true, succeeded: turn.status == "completed"))
    rescue StandardError => error
      warn "the report line could not be printed: #{error.class}: #{error.message.to_s[0, 200]}"
    end

    def upload_ids(entries)
      entries.flat_map { |entry| Array(entry["parts"]) }
        .select { |part| part["type"] == "upload" }.map { |part| part["upload_public_id"] }
    end

    def report(chat, first, second)
      puts "\n--- live vision -----------------------------------------------"
      puts "model:         #{MODEL}"
      puts "conversation:  #{chat.public_id}"
      puts "colour:        #{first.text.to_s.strip[0, 120].inspect}"
      puts "shape:         #{second.text.to_s.strip[0, 120].inspect}"
      puts "--------------------------------------------------------------"
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{tail}"
    end
end
