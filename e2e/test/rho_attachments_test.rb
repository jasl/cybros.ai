require "test_helper"
require "base64"
require "cgi/escape"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/device_authorization_budget"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# A PICTURE FROM A TERMINAL: `rho do --attach PATH` and `rho say --attach PATH` post the PATH to the
# daemon — the one holder of the member plane — which reads the bytes, stages them through the
# kernel's ingest as RHO'S OWN USER and names the ids on the input beside the words; the kernel
# binds them to the turn and the mock, a vision row, reads the picture natively (its echo names the
# type and the decoded size, never a data URL). `rho inputs` shows the picture on a queued row; a
# steer with a picture is refused at rho's edge with the kernel's word before any call. What is
# asserted is read through the doors — the sealed request off the deck, the turn's `attachments`
# descriptor, the queue listing — never the model's prose beyond the echo line.
#
# ONE CEREMONY PER FILE (the `processes` shape): one daemon, one RHO_HOME,
# one grant; each case opens its own conversation.
class RhoAttachmentsTest < Minitest::Test
  MODEL = E2E::CatalogOverlay::ATTACHMENTS_MODEL
  POLL = 1
  AWAIT_SECONDS = 90
  # The window `rho inputs` reads a queued row in: turn 2 holds the
  # conversation for the harness's one hold, inside which a `say`/`inputs`
  # verb pair lands (`E2E::RhoDaemon::HOLD_SECONDS`).
  HOLD_SECONDS = E2E::RhoDaemon::HOLD_SECONDS
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )
  # The echo names the DECODED size of the data URL on the wire — the
  # prepared variant's (`upload_media.rb:81`, re-encoded by libvips: 283 bytes
  # for this 1x1 PNG), never the upload's 70 (`attached:` prints that one).
  ECHOED_PNG = %r{\[image image/png [1-9]\d* bytes\]}

  World = Struct.new(:daemon, :home, :steward, :actor, :workspace_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-attachments-e2e")
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @world
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
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { RhoAttachmentsTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @client.workspace(@workspace_public_id)
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
    warn "Could not capture the rho attachments E2E logs: #{error.class}: #{error.message}"
  end

  # TURN 1 (`rho do --attach`): the terminal prints what the daemon staged;
  # the turn's variant shows the picture as the row's fact; the sealed
  # request carries the `upload` part in the user entry (a vision row
  # reads it natively) and the echo names the bytes; the upload was staged
  # under RHO's user, so the steward — who typed the verb — cannot read it
  # on their own creator scope. TURN 2 holds the conversation; TURN 3 is
  # queued with a picture by `rho say --attach` while it runs, and `rho
  # inputs` shows the picture on the waiting row; once turn 3 settles, its
  # sealed request carries turn 1's picture in the seed and its own in the
  # user entry. A steer with a picture never reaches the daemon.
  def test_a_picture_rides_rho_do_and_rho_say_and_the_queue_shows_it
    picture = picture_file("diagram.png")

    # Two native pictures reserve 5,000 tokens before the policy, prefaces and text. This
    # journey's finite 12,288-token row fits their retained history without changing the
    # small shared mock window. The first answer reports only actual wire images so it
    # does not echo the policy into history. AttachmentsTest covers the compaction cut.
    output, status = @daemon.cli("do", "!mock echo=images -- what is this?", "--model", MODEL, "--dir", project,
      "--instructions", "Use bash to hold the conversation while another input is queued.", "--attach", picture)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation, turn_one = %w[conversation turn].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
    refute_includes [conversation, turn_one], nil, "rho do printed fewer than two ids:\n#{output}"
    assert_match(%r{^attached:\s+diagram\.png \(image/png, #{PNG.bytesize} B\)$}, output,
      "the terminal prints what the daemon staged, as the kernel described the bytes")

    chat = @workspace.conversations.conversation(conversation)
    first = await_turn(chat, turn_one, "completed")
    descriptor = first.active_variant.attachments&.first
    refute_nil descriptor, "the reply turn shows the picture its prompt carried: #{first.to_h.inspect}"
    assert_equal ["diagram.png", "image/png", PNG.bytesize], [descriptor.filename, descriptor.content_type, descriptor.byte_size]
    sealed = sealed_request_of(chat, turn_one)
    user_entry = sealed.entries.reverse.find { |entry| entry["role"] == "user" && entry.key?("parts") }
    refute_nil user_entry, "the sealed request has a parts-shaped user entry: #{sealed.entries.inspect}"
    assert_equal %w[text text upload], part_types(user_entry), "the kind, the words, then the picture, natively on a vision row"
    assert_equal "Conversation kind: conversation.", user_entry.fetch("parts").fetch(0).fetch("text")
    assert_equal "!mock echo=images -- what is this?", user_entry.fetch("parts").fetch(1).fetch("text")
    assert_equal descriptor.public_id, user_entry["parts"].last["upload_public_id"]
    assert_match ECHOED_PNG, first.active_variant.content.to_s,
      "the mock read the picture: its echo names the type and the decoded size"
    refute_includes first.active_variant.content.to_s, "data:image", "no data URL leaves the wire"
    assert_raises(CybrosAgent::Api::NotFound, "staged under rho's own user: the steward's creator scope cannot see it") do
      @client.uploads.fetch(descriptor.public_id)
    end

    # A steer takes no picture: refused at rho's edge, nothing posted.
    refused, status = @daemon.cli("say", conversation, "now", "--attach", picture, "--mode", "steer")
    refute_predicate status, :success?, "a steer with a picture must be refused:\n#{refused}"
    assert_match(/attachments_not_steerable/, refused, "the kernel's word, one sentence")
    assert_empty chat.inputs.list.items, "nothing reached the queue"

    # Turn 2 holds the conversation; turn 3 waits behind it with a picture.
    held, status = @daemon.cli("say", conversation, hold_script, "--mode", "queue")
    assert_predicate status, :success?, "rho say (the hold) failed:\n#{held}"
    said, status = @daemon.cli("say", conversation, "!mock -- and this one?", "--attach", picture)
    assert_predicate status, :success?, "rho say --attach failed:\n#{said}"
    assert_match(/^queued:\s+(\S+) \(pending\)$/, said, "--attach implies a queued turn")
    queued_id = said[/^queued:\s+(\S+)/, 1]
    assert_match(%r{^attached:\s+diagram\.png \(image/png, #{PNG.bytesize} B\)$}, said)
    listing, status = @daemon.cli("inputs", conversation)
    assert_predicate status, :success?, "rho inputs failed:\n#{listing}"
    # The row's origin closes the line: the daemon posted it on rho's own
    # member plane, so it is an agent's word, not the person's.
    assert_match(%r{^  pending    #{Regexp.escape(queued_id)}  direct_reply  "!mock -- and this one\?"  attachments: diagram\.png \(image/png, #{PNG.bytesize} B\)  \[agent\]$},
      listing, "the waiting row shows its picture, staged as rho's user")

    third = await("turn 3 never settled") do
      chat.turns.list.items.select { |turn| turn.role == "assistant" && turn.position > first.position }
        .sort_by(&:position).drop(1).find { |turn| turn.status == "completed" }
    end
    compactions = chat.events(limit: 200).select { |event| event.type == "context_compacted" }
    assert_empty compactions, "this picture-carriage fixture must fit without replacing history with a summary"
    sealed = sealed_request_of(chat, third.public_id)
    uploads = upload_ids(sealed.entries)
    assert_equal 2, uploads.length, "turn 1's picture rides the seed, turn 3's own the user entry: #{sealed.entries.inspect}"
    assert_equal descriptor.public_id, uploads.first, "history carries the earlier picture natively"
    assert_equal third.active_variant.attachments.first.public_id, uploads.last
    refute_equal uploads.first, uploads.last, "the second `--attach` staged the bytes again: a second upload"
  end

  # A path that is not a file is refused by the CLI before any call — no
  # daemon round trip, no queue row, one sentence.
  def test_a_missing_path_is_refused_before_any_call
    output, status = @daemon.cli("do", "!mock -- what is this?", "--model", MODEL, "--dir", project,
      "--attach", File.join(@world.home, "gone.png"))

    refute_predicate status, :success?
    assert_match(/no such file to attach: .*gone\.png/, output)
    refute_match(/^conversation:/, output, "nothing was opened")
  end

  private

    def picture_file(name)
      File.join(project, name).tap { |path| File.binwrite(path, PNG) }
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # Turn 2's script: one bash call that sleeps, so the conversation is busy while turn 3 is queued
    # and listed. The mock's clock is the count of tool answers in its whole input — turn 1 made
    # none, so no padding. The hold speaks its short remainder instead of echoing the whole
    # request into history. The first answer's image echo still proves the picture reached
    # the provider; the third turn must carry that original picture natively without a summary.
    def hold_script
      "!mock tool_call=bash:#{CGI.escape(JSON.generate("command" => "sleep #{HOLD_SECONDS}"))} " \
        "reply=#{CGI.escape("hold the line")} -- hold the line"
    end

    def sealed_request_of(chat, turn_public_id)
      deck = chat.turns.variants(turn_public_id)
      chat.turns.request(turn_public_id, deck.active.public_id)
    end

    def part_types(entry) = Array(entry["parts"]).map { |part| part["type"] }

    def upload_ids(entries)
      entries.flat_map { |entry| Array(entry["parts"]) }
        .select { |part| part["type"] == "upload" }.map { |part| part["upload_public_id"] }
    end

    def await_turn(chat, turn_public_id, status)
      await("turn #{turn_public_id} never reached #{status}") do
        turn = chat.turns.list.items.find { |row| row.public_id == turn_public_id }
        flunk "the turn failed: #{turn.to_h.inspect}" if turn&.status == "failed"
        turn if turn&.status == status
      end
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

    def warn_log(path, label)
      return unless path && File.file?(path)

      warn "---- #{label} (#{path}) ----"
      warn File.read(path, encoding: Encoding::UTF_8).lines.last(80).join
    end
end
