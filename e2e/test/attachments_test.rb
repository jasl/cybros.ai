require "test_helper"
require "base64"
require "json"
require "net/http"
require "securerandom"
require "stringio"
require "support/actor_provisioning"
require "support/peer_program"
require "support/pdf_document"
require "support/red_square_png"
require "support/steward_session"

# Mixed PDF/image inputs retain their order through the deployed model request, and PDF
# history follows the selected model's capability. A separate compaction journey replaces
# the picture with a summary pointer and checks that it leaves subsequent sealed requests.
# Assertions read the public sealed request; a mock echo alone could contain an earlier image.
class AttachmentsTest < Minitest::Test
  VISION = "dev/mock-text".freeze
  DOCUMENT = E2E::CatalogOverlay::DOCUMENT_MODEL
  TURN_TIMEOUT = 120
  # 120 requests a minute per identity: polls are paced.
  POLL = 1.0
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  # The mock's second witness: the media type and the DECODED size of the
  # data URL it was handed. The wire carries the PREPARED variant (A.0/A.5:
  # the <=1600 px re-encode, `upload_media.rb:81`), so the count is the
  # image library's — 283 bytes for this 1x1 PNG under the harness's libvips,
  # never the upload's 70 — and is not pinned; only that bytes were decoded.
  ECHOED_PNG = %r{\[image image/png [1-9]\d* bytes\]}
  PEER_TOOL = {
    "type" => "function",
    "function" => { "name" => "note", "description" => "Keep a note",
                    "parameters" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } } },
  }.freeze

  World = Struct.new(:steward, :actor, :room_public_id, :peer, keyword_init: true)

  class << self
    attr_reader :world

    # The steward's session, an account-wide room the peer can enter, and
    # the peer: declared once, a speaker's engine — its own `note` it never
    # calls, the kernel's memory family beside it (a declaration may alias
    # a kernel tool; the kernel serves it, so (4)'s scripted call reaches
    # the approval stage), `bypass`, the kernel's compaction.
    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      E2E.enable_dev_lane!
      E2E.hosts.start
      steward_client = CybrosAgent::Client.new(base_url: base_url, credential: steward.member_token)
      room = steward_client.workspaces.create(
        name: "Attachments #{SecureRandom.hex(3)}", access_mode: "account_wide", idempotency_key: SecureRandom.uuid
      ).workspace.public_id
      peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "attachments-b")
      peer.client.profile.declare_configuration(
        tool_definitions: [PEER_TOOL] + kernel_memory_tools(steward_client), approval_mode: "bypass",
        approval_rules: nil, prompt_mechanism: "default", compaction_policy: { "mode" => "kernel" }
      )
      @world = World.new(steward: steward, actor: actor, room_public_id: room, peer: peer)
    end

    # The kernel's memory tools as the catalog declares them — executed
    # by the kernel itself, so a scripted call needs no runner.
    def kernel_memory_tools(client)
      client.tools.list.select { |entry| entry.canonical_name.start_with?("nexus.memory.") }.map(&:definition)
    end
  end

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @steward = @world.steward
    @room = @world.room_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @conversations = @client.workspace(@room).conversations
  end

  def teardown
    return if passed?

    %i[runner jobs].each do |host|
      warn_log(E2E.hosts.log_path(host), "nexus #{host}")
    rescue StandardError
      nil
    end
  end

  def test_a_pdf_and_image_keep_their_order_and_pdf_history_follows_the_selected_models_capability
    bytes = E2E::PdfDocument.bytes
    pdf = @client.uploads.create_io(StringIO.new(bytes), filename: "report.dat")
    assert_equal ["report.pdf", "application/pdf", bytes.bytesize], [pdf.filename, pdf.content_type, pdf.byte_size]
    picture = stage_png("diagram.png")
    chat = open_conversation("Native PDF and image")

    first = ask(chat, "inspect both", model: DOCUMENT, attachments: [pdf.public_id, picture.public_id])
    entry = sealed_request_of(chat, first).entries.last
    assert_equal %w[text upload upload], part_types(entry)
    assert_equal [pdf.public_id, picture.public_id], upload_ids([entry])
    assert_equal [pdf.public_id, picture.public_id], first.active_variant.attachments.map(&:public_id)
    assert_includes first.text, "[file report.pdf application/pdf #{bytes.bytesize} bytes]"
    assert_match ECHOED_PNG, first.text
    refute_includes first.text, "base64"

    # The same retained prompt becomes a tool reference on an image-only row.
    second = ask(chat, "!mock echo=content -- inspect the earlier file", model: VISION)
    later = sealed_request_of(chat, second).entries
    assert_equal [picture.public_id], upload_ids(later)
    assert_includes texts_of(later).join("\n"), "nexus://uploads/#{pdf.public_id}"
    assert_includes texts_of(later).join("\n"), "file content is available through attachment tools"

    third = ask(chat, "!mock echo=content -- read the document again", model: DOCUMENT)
    assert_equal [pdf.public_id, picture.public_id], upload_ids(sealed_request_of(chat, third).entries)
  end

  # (6): the pointer in the summarizer's request, and the picture gone
  # from the wire after the cut.
  def test_a_compaction_summary_reads_the_picture_as_a_pointer_and_the_picture_leaves_the_wire_after_the_cut
    picture = stage_png("diagram.png")
    peer = @world.peer
    chat = open_conversation("Compaction half", answering_user_public_id: peer.public_id)

    # TURN 1, loop-backed: the picture beside the words, and a reported
    # usage past the dev window (8 192) that arms the next head's summary.
    first = ask(chat, "!mock usage=9000:5 -- describe the diagram", model: VISION,
      attachments: [picture.public_id])
    assert_equal peer.public_id, first.answering_user_public_id, "the peer answered: a loop-backed turn"
    loop_one = first.active_variant.run_public_id
    refute_nil loop_one, "a loop backs the peer's turn: #{first.to_h.inspect}"
    round_one = sealed_entries(loop_one, "r1")
    assert_equal [picture.public_id], upload_ids(round_one), "round one sealed the picture natively"

    # TURN 2 opens behind the between-turn summary. Its own `!mock --`
    # keeps the last marker line the turn's own (the summary carries turn
    # 1's line as the assistant's echoed words).
    second = ask(chat, "!mock -- what else?", model: VISION)
    compacted = feed(chat.public_id).select { |item| item["type"] == "context_compacted" }
    assert_equal 1, compacted.size, "exactly one repair on one wall: #{compacted.map { |c| c["payload"] }.inspect}"
    payload = compacted.first.fetch("payload")
    assert_equal %w[kernel usage], payload.values_at("mode", "trigger"), payload.inspect
    refute_nil payload["summary_turn_public_id"], "a summary turn between the two: #{payload.inspect}"

    # THE SUMMARIZER'S SEALED REQUEST: the one model task of the summary
    # turn's loop (`k1`; the between-turn payload names the loop, not the key).
    summary_loop = payload.fetch("run_public_id")
    summarizer_keys = loop_row(summary_loop).fetch("tasks").select { |task| task["kind"] == "model_task" }
      .map { |task| task.fetch("key") }
    assert_equal 1, summarizer_keys.length, "one model task in the summary loop: #{summarizer_keys.inspect}"
    summarizer_key = summarizer_keys.first
    handed = sealed_entries(summary_loop, summarizer_key)
    summarizer = texts_of(handed).join("\n")
    assert_includes summarizer, "describe the diagram\n#{pointer_line(picture)}",
      "the summarizer reads the picture as a pointer after the words: #{summarizer[0, 600].inspect}"
    refute_includes summarizer, picture.public_id, "a pointer names the picture, never its id"
    refute_includes summarizer, "data:image", "and never its bytes"
    assert_empty upload_ids(handed), "the summarizer's request seals no upload part"

    loop_two = second.active_variant.run_public_id
    after_cut = sealed_entries(loop_two, "r1")
    assert_empty upload_ids(after_cut), "after the cut the picture leaves the wire with the turns the summary replaced"
    assert_includes texts_of(after_cut).join("\n"), pointer_line(picture),
      "what remains of the picture is the summary's pointer"
    refute_includes texts_of(after_cut).join("\n"), picture.public_id
  end

  private

    def kernel_memory_tools = self.class.kernel_memory_tools(@client)

    # The settled assistant turn past `after`, through the SDK; a failed
    # one fails HERE with its row.
    def await_reply(chat, after:, what:)
      await("a reply to #{what}") do
        turns = chat.turns.list.items
        newer = turns.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        @observed = { turns: turns.map { |turn| [turn.position, turn.role, turn.status] },
                      tasks: loop_tasks_of(turns.select { |turn| turn.role == "assistant" }.max_by(&:position)) }
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # The newest assistant turn's loop tasks, for a loud timeout.
    def loop_tasks_of(turn)
      loop_id = turn&.active_variant&.run_public_id
      return nil if loop_id.nil?

      loop_row(loop_id).fetch("tasks").map { |task| task.values_at("key", "status", "error_key") }
    end

    def stage_png(filename)
      upload = @client.uploads.create_io(StringIO.new(PNG), filename: filename)
      assert_equal "image/png", upload.content_type, "the bytes decide the type"
      assert_equal PNG.bytesize, upload.byte_size
      upload
    end

    def open_conversation(title, **fields)
      @conversations.conversation(
        @conversations.create(title: title, idempotency_key: SecureRandom.uuid, **fields).public_id
      )
    end

    # Raw input carries `attachments` beside `text` under `input`. The helper returns the settled
    # reply turn.
    def ask(chat, text, model:, attachments: nil)
      after = chat.turns.list.items.map(&:position).max || -1
      body, status = post_input(chat, { "kind" => "direct_reply", "text" => text, "model" => { "model" => model },
                                        "attachments" => attachments }.compact)
      assert_equal 202, status, "the input door refused: #{body.inspect}"
      await("a reply to #{text.inspect}") do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    def post_input(chat, input)
      uri = URI.join(@base_url, "/agent_api/v1/workspaces/#{@room}/conversations/#{chat.public_id}/inputs")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate("input" => input)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      [JSON.parse(response.body.to_s.empty? ? "{}" : response.body.force_encoding(Encoding::UTF_8)), response.code.to_i]
    end

    # THE DEBUG DOOR: the active candidate's sealed request, off the deck.
    def sealed_request_of(chat, turn)
      deck = chat.turns.variants(turn.public_id)
      chat.turns.request(turn.public_id, deck.active.public_id)
    end

    def part_types(entry) = Array(entry["parts"]).map { |part| part["type"] }

    def index_line(upload)
      "[Attachment: #{upload.filename} (image/png, #{delimited(upload.byte_size)} bytes) — " \
        "image content omitted: this model does not support image input]"
    end

    def pointer_line(upload)
      "[Attachment: #{upload.filename} (image/png, #{delimited(upload.byte_size)} bytes) — " \
        "not carried past the summary; ask for it again if needed]"
    end

    def delimited(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

    # ---- the member plane, as the steward: a loop's sealed rounds ----

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def loop_row(loop)
      document = agent_api("/agent_api/v1/workspaces/#{@room}/runs/#{loop}")
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def sealed_entries(loop, task_key)
      document = agent_api("/agent_api/v1/workspaces/#{@room}/runs/#{loop}/tasks/#{task_key}/request")
      entries = document.dig("request", "entries")
      refute_nil entries, "round #{task_key} of #{loop} has no sealed request: #{document.inspect}"
      entries
    end

    def upload_ids(entries)
      entries.flat_map { |entry| entry.is_a?(Hash) ? Array(entry["parts"]) : [] }
        .select { |part| part["type"] == "upload" }.map { |part| part["upload_public_id"] }
    end

    # Every string on the wire EXCEPT an `upload` part's own id field: the
    # part names its upload by public id (that is the wire's bookkeeping),
    # and "no id in any text" asks whether the id reached the model as words.
    def texts_of(value)
      case value
      when String then [value]
      when Array then value.flat_map { |item| texts_of(item) }
      when Hash then value.except("upload_public_id").values.flat_map { |item| texts_of(item) }
      else []
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

    def await(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        result = begin
          yield
        rescue CybrosAgent::Api::RateLimited => throttle
          flunk("the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s)")
        end
        return result if result
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          seen = @observed ? " (last seen: #{@observed.inspect})" : ""
          flunk("the deployment never reached #{what}#{seen}")
        end

        sleep POLL
      end
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{tail}"
    end
end
