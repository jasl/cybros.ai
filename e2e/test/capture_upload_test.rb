require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "stringio"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/red_square_png"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# CAPTURES. An executor PUBLISHES bytes on its own plane, a result NAMES them with a
# `resource_link`, and ONE bytes read serves them by the upload's own rule — its creator, or a
# reader of a row that names it. The world: an agent-mode rho under the empty-extensions prelude (it
# declares the echo tools as its own and serves none), and a harness TOOLS PROVIDER whose `capture`
# stages the pure-Ruby red square as ITS OWN creator and commits `content: [text, resource_link]` +
# `title` + `metadata` — the pool row addressed to the role, claimed by the provider (the
# executor_plane E9 shape). Every read of the bytes is a principal's: rho's own, driven through `rho
# fetch` (exe/rho); the steward's (rho's dedicated workspace is the steward's, so the funnel admits
# them); the provider's transport credential (401 — not this plane's); the account's other Human
# (404 — a stranger to the workspace); an uploaded-never-committed capture (404 to everyone: the
# creator has no member read and nothing names it).
#
# (b)3's attachment half — the SAME read serving a conversation's attachment — rides `rho do
# --attach` on this file's own conversation; the `none` narrowing is `conversation_acl`'s case
# (GROUP 3). (b)4 is the provider linking a User's upload and a nonexistent id: the kernel's `422
# unknown_result_upload`, the park standing, and the same token then committing text alone. (b)6 is
# the fallback's absence: a structure-only result reads `""` on the task AND in the next sealed
# request (`rho request`, never the body's text alone). (b)5 is the images rider: TWO captures in
# ONE round (the mock's `+` group) ride the NEXT sealed request as both results, then ONE
# picture-only user message with both `upload` parts in that order — the echo then carries two image
# pointers, the mock's own witness that pictures left the process; on `dev/mock-text-only` the RULED
# line stands in each picture's place (no part, no upload id); and a `.log` capture adds neither a
# part nor a line (the non-media half).
#
# ONE CEREMONY PER FILE: the steward's session, rho's daemon (its own
# home) and the provider's grant are booted once for every case here.
class CaptureUploadTest < Minitest::Test
  EMPTY_PRELUDE = File.expand_path("../support/empty_extensions_prelude.rb", __dir__)
  MODEL = "dev/mock-text".freeze
  PROVIDER_IDENTIFIER = "cybros-e2e-capture-provider".freeze
  PROVIDER_DISPLAY_NAME = "E2E capture provider".freeze
  PROVIDER_TOOLS = %w[capture read structure].freeze
  LOOP_POLL = 1
  AWAIT_SECONDS = 120
  PNG = E2E::RedSquarePng.bytes

  World = Struct.new(:daemon, :home, :provider_home, :steward, :actor, :workspace_public_id, :provider,
    :provider_credential, :shared_human, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-capture-upload-e2e")
      provider_home = Dir.mktmpdir("e2e-capture-provider")
      File.write(File.join(home, "settings.json"), JSON.generate({ "extensions" => ["rho/dev"], "extension_paths" => [] }))
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home,
        env: { "RUBYOPT" => "-r#{EMPTY_PRELUDE}", "RHO_MODE" => "agent" })
      @world = World.new(daemon: daemon, home: home, provider_home: provider_home, steward: steward, actor: actor,
        shared_human: provisioning.shared_human)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      grant_provider!(base_url, actor)
      @world
    end

    # THE GRANT, then the process: the transport credential comes only through the browser ceremony
    # a person completes and reaches the child on stdin. A tools PROVIDER: never a binding, so its
    # rows are pool rows addressed to the role.
    def grant_provider!(base_url, actor)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        runner_identifier: PROVIDER_IDENTIFIER, runner_display_name: PROVIDER_DISPLAY_NAME,
        executor_kind: "tools_provider"
      )
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      offer = E2E::RunnerGrant.scope_offer(actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = device.await_credentials(authorization)
      @world.provider_credential = credentials.executor_access_token
      @world.provider = E2E::ExecutorProcess.new(base_url: base_url, home: @world.provider_home,
        credential: credentials.executor_access_token, kind: :tools_provider, tools: PROVIDER_TOOLS)
      @world.provider.start
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
        world.provider&.stop
      rescue StandardError => error
        warn "Could not stop the provider process: #{error.class}: #{error.message}"
      end
      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.provider_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
    end
  end

  Minitest.after_run { CaptureUploadTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @provider = @world.provider
    @shared = @world.shared_human
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @shared_client = CybrosAgent::Client.new(base_url: @base_url, credential: @shared.member_token)
    assert_equal "tools_provider", @provider.announced_kind
    assert_equal PROVIDER_TOOLS.sort, @provider.announced.sort
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(File.join(@world.home, "log", "rho.log"), "rho structured log")
    warn_log(@provider&.log_path, "provider process log")
  rescue StandardError => error
    warn "Could not capture the capture upload E2E logs: #{error.class}: #{error.message}"
  end

  # (b)1 + (b)2. The provider stages the PNG as ITS OWN creator and names it;
  # the task read renders text, link, title and metadata with `output` the
  # text alone; then every principal's read of the bytes.
  def test_a_capture_is_staged_by_the_executor_named_by_its_result_and_served_by_the_uploads_own_rule
    loop_id = rho_do("!mock tool_call=capture tool_args=#{args("note" => "one")} -- what did you see?")
    completed = await_loop_completion(loop_id)
    task = tool_task(completed, "capture")
    assert_equal "completed", task.fetch("status"), task.inspect
    key = task.fetch("key")
    assert_includes @provider.claimed_keys, key, "the provider's own log says it took the pool row"
    captured = provider_event("captured", loop_id, key)
    refute_nil captured, "the provider staged a capture for this row"
    upload_id = captured.fetch("upload_public_id")
    assert_equal upload_id, captured.fetch("linked")

    creator = E2E.operator.upload_creator!(upload_id)
    refute_nil creator.fetch("creating_executor_id"), "staged as the executor's own"
    assert_nil creator.fetch("creating_user_id"), "exactly one creator: never a member"

    detail = @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop_id).task(key)
    assert_equal "capture", detail.task.tool_name
    assert_equal 2, detail.content.length, detail.content.inspect
    text, link = detail.content
    assert_equal "text", text.fetch("type")
    assert_match(/\Aecho:capture:/, text.fetch("text"))
    assert_equal({ "type" => "resource_link", "uri" => "nexus://uploads/#{upload_id}", "name" => "square.png",
                   "mimeType" => "image/png", "size" => PNG.bytesize, "title" => "a red square" }, link)
    assert_equal text.fetch("text"), detail.output, "the model's channel is the text alone; the link is the client's"
    assert_equal "capture", detail.title
    assert_equal({ "checkpoint" => { "step" => 1 }, "upload_public_id" => upload_id }, detail.metadata)

    # rho's OWN read, through the shipped binary: the loop's creator.
    bytes, status = @daemon.cli_bytes("fetch", upload_id)
    assert_predicate status, :success?, bytes.dup.force_encoding(Encoding::UTF_8).scrub
    assert_equal PNG, bytes, "`rho fetch` prints the capture whole, byte for byte"
    # …and its thumbnail: the kernel's named representation through the same verb — a PNG of the
    # square's own size (24 px is under the 256 px bound), pinned by its header, never byte for
    # byte.
    small, status = @daemon.cli_bytes("fetch", upload_id, "--thumbnail")
    assert_predicate status, :success?, small.dup.force_encoding(Encoding::UTF_8).scrub
    assert_equal [E2E::RedSquarePng::SIDE, E2E::RedSquarePng::SIDE], E2E::RedSquarePng.dimensions(small),
      "`rho fetch --thumbnail` prints the kernel's PNG"

    # The steward reads through the workspace funnel (rho's room is theirs).
    io = StringIO.new
    assert_equal 200, @steward_client.uploads.bytes(upload_id, io).status
    assert_equal PNG, io.string.b
    tail = StringIO.new
    assert_equal 206, @steward_client.uploads.bytes(upload_id, tail, range: "bytes=#{PNG.bytesize - 12}-").status
    assert_equal PNG[-12..], tail.string.b, "a Range answers the slice: HTTP's own chunked read"
    response = bytes_response(upload_id, @steward.member_token)
    assert_equal "200", response.code
    assert_equal "image/png", response["content-type"], "the detected type"
    assert_equal "bytes", response["accept-ranges"]

    # The provider's own credential is not this plane's; the other Human is
    # a stranger to the workspace.
    assert_equal "401", bytes_response(upload_id, @world.provider_credential).code
    assert_raises(CybrosAgent::Api::NotFound) { @shared_client.uploads.bytes(upload_id, StringIO.new) }

    # (b)2's last case: staged, never named — nobody's.
    orphan_loop = rho_do("!mock tool_call=capture tool_args=#{args("orphan" => true)} -- and now?")
    orphan_key = tool_task(await_loop_completion(orphan_loop), "capture").fetch("key")
    orphan = provider_event("captured", orphan_loop, orphan_key)
    refute_nil orphan
    assert_nil orphan.fetch("linked"), "the provider staged it and named nothing"
    orphan_id = orphan.fetch("upload_public_id")
    refute_equal upload_id, orphan_id
    assert_equal "404", bytes_response(orphan_id, @steward.member_token).code, "uploaded, never committed: absent"
    assert_raises(CybrosAgent::Api::NotFound) { @shared_client.uploads.bytes(orphan_id, StringIO.new) }
    _, fetch_status = @daemon.cli_bytes("fetch", orphan_id)
    refute_predicate fetch_status, :success?, "`rho fetch` of a capture nobody named is the kernel's 404"
    assert_nil @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(orphan_loop)
      .task(orphan_key).title, "an unlinked capture commits the text alone: no title"
  end

  # (b)3, the attachment half: the SAME read serves this conversation's own
  # attachment to that conversation's reader, and 404s the stranger.
  def test_the_same_read_serves_an_attachment_of_this_journeys_conversation_to_its_reader
    picture = File.join(project, "square.png")
    File.binwrite(picture, PNG)
    output, status = @daemon.cli("do", "!mock -- what is this?", "--model", MODEL, "--dir", project, "--attach", picture)
    assert_predicate status, :success?, "rho do --attach failed:\n#{output}"
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    refute_nil conversation_id, output
    assert_match(%r{^attached:\s+square\.png \(image/png, #{PNG.bytesize} B\)$}, output)

    chat = @steward_client.workspace(@workspace_public_id).conversations.conversation(conversation_id)
    attachment = await("the turn never listed its attachment") do
      chat.turns.list.items.flat_map { |turn| Array(turn.active_variant&.attachments) }.first
    end
    creator = E2E.operator.upload_creator!(attachment.public_id)
    refute_nil creator.fetch("creating_user_id"), "an attachment is a member's upload"
    assert_nil creator.fetch("creating_executor_id")

    io = StringIO.new
    assert_equal 200, @steward_client.uploads.bytes(attachment.public_id, io).status
    assert_equal PNG, io.string.b, "the conversation's reader reads its attachment through the one read"
    assert_raises(CybrosAgent::Api::NotFound) { @shared_client.uploads.bytes(attachment.public_id, StringIO.new) }
    bytes, fetch_status = @daemon.cli_bytes("fetch", attachment.public_id)
    assert_predicate fetch_status, :success?
    assert_equal PNG, bytes, "the poster reads it back through `rho fetch`"
  end

  # (b)4. A link naming a User's upload, or a nonexistent id, is
  # `422 unknown_result_upload` with the park STANDING: the same token then
  # commits text alone and the row settles — the provider's log carries the
  # refusal, the loop completes, the task reads the text and no link.
  def test_a_link_to_an_upload_that_is_not_the_executors_own_is_refused_and_the_same_token_then_commits_text
    users_upload = @steward_client.uploads.create_io(StringIO.new(PNG), filename: "mine.png")
    [users_upload.public_id, SecureRandom.uuid_v7].each do |foreign|
      loop_id = rho_do("!mock tool_call=capture tool_args=#{args("link_to" => foreign)} -- linked?")
      task = tool_task(await_loop_completion(loop_id), "capture")
      key = task.fetch("key")
      assert_equal "completed", task.fetch("status"), task.inspect
      refused = provider_event("capture_link_refused", loop_id, key)
      refute_nil refused, "the kernel refused the foreign link: #{@provider.log_text}"
      assert_equal "unknown_result_upload", refused.fetch("code")
      assert_equal foreign, refused.fetch("linked")

      detail = @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop_id).task(key)
      assert_equal [%w[type text]], detail.content.map { |block| ["type", block.fetch("type")] },
        "the same token committed the text alone after the refusal: #{detail.content.inspect}"
      assert_nil detail.title
      assert_nil detail.metadata
    end
    io = StringIO.new
    assert_equal 200, @steward_client.uploads.bytes(users_upload.public_id, io).status, "the User's own row stays theirs"
    assert_equal PNG, io.string.b
  end

  # (b)5, the media half: two captures in one round → the next request carries both results, then
  # ONE picture-only message with both parts in result order, the seal binding both; and the mock's
  # echo — what the model was shown — carries two image pointers.
  def test_two_captures_in_one_round_ride_one_picture_message_after_the_last_result
    loop_id = rho_do("!mock tool_call=capture&capture -- what did you see?")
    completed = await_loop_completion(loop_id)
    keys, ids = captured_in_call_order(completed, loop_id)
    assert_equal 2, ids.uniq.length, "two captures, two rows: #{ids.inspect}"

    round, entries = next_request_entries(completed, loop_id)
    results = entries.each_index.select { |index| entries[index].dig("payload", "type") == "function_call_output" }
    assert_equal 2, results.length, "both results ride the next request: #{entries.inspect}"
    picture = entries[results.last + 1]
    refute_nil picture, "ONE picture message follows the round's LAST result: #{entries.inspect}"
    assert_equal "user", picture["role"]
    assert_equal ids.map { |id| { "type" => "upload", "upload_public_id" => id } }, picture["parts"],
      "both parts, in result order (#{keys.join(", ")}), and nothing else in the message"
    parts = entries.flat_map { |entry| Array(entry["parts"]) }
    assert_equal 2, parts.count { |part| part["type"] == "upload" }, "the pictures ride once, in one message"
    words = entries.reject { |entry| entry.equal?(picture) }
    ids.each { |id| refute_includes JSON.generate(words), id, "no upload id reaches the model as words" }

    echo = @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop_id).task(round).output.to_s
    assert_equal 2, echo.scan(%r{\[image image/png \d+ bytes\]}).length,
      "the mock echoes each lowered picture as a pointer — the second witness: #{echo.inspect}"
  end

  # (b)5 on a text-only row: the RULED index line in each picture's place
  # — `attachment_line.rb`'s bytes, by regex — no `upload` part, no id.
  def test_on_a_text_only_row_the_ruled_line_stands_in_each_pictures_place
    loop_id = rho_do("!mock tool_call=capture&capture -- and now?", model: "dev/mock-text-only")
    completed = await_loop_completion(loop_id)
    _, ids = captured_in_call_order(completed, loop_id)

    _, entries = next_request_entries(completed, loop_id)
    results = entries.each_index.select { |index| entries[index].dig("payload", "type") == "function_call_output" }
    assert_equal 2, results.length, entries.inspect
    lines = entries[results.last + 1]
    refute_nil lines, "the lines stand where the picture message would: #{entries.inspect}"
    assert_equal "user", lines["role"]
    assert_equal %w[text text], lines["parts"].map { |part| part["type"] }, "one line per picture, no upload part"
    lines["parts"].each do |part|
      assert_match(%r{\A\[Attachment: square\.png \(image/png, [\d,]+ bytes\) — image content omitted: this model does not support image input\]\z},
        part["text"], "the ruled line, byte for byte")
    end
    output = JSON.generate(entries)
    refute(entries.flat_map { |entry| Array(entry["parts"]) }.any? { |part| part["type"] == "upload" })
    ids.each { |id| refute_includes output, id, "no upload id reaches the model" }
  end

  # (b)5, the non-media half: a capture that is not a picture — a `.log` — is the client's alone:
  # the NEXT sealed request carries the result, and neither an `upload` part nor the ruled index
  # line for it. The tool's own sentence already names what a model needs.
  def test_a_non_media_capture_adds_neither_a_part_nor_a_line_to_the_next_request
    loop_id = rho_do("!mock tool_call=capture tool_args=#{args("filename" => "trace.log")} -- and then?")
    completed = await_loop_completion(loop_id)
    task = tool_task(completed, "capture")
    key = task.fetch("key")
    detail = @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop_id).task(key)
    link = detail.content.find { |block| block.fetch("type") == "resource_link" }
    refute_nil link, "the capture was linked: #{detail.content.inspect}"
    assert_equal "trace.log", link.fetch("name")
    # The kernel's word: the bytes decide the type and no name hint reaches
    # Marcel (`ContentUploads::Create`), so text bytes stage as
    # `application/octet-stream` — whatever the name says, not a picture.
    assert_equal "application/octet-stream", link.fetch("mimeType"), "the detected type is not a picture"

    rounds = completed.fetch("tasks").select { |row| row.fetch("kind") == "model_task" }.map { |row| row.fetch("key") }
    assert_operator rounds.length, :>=, 2, "the mock ran a round after the tool: #{rounds.inspect}"
    output, status = @daemon.cli("request", loop_id, rounds.last)
    assert_predicate status, :success?, output
    entries = JSON.parse(output.split("entries:\n", 2).fetch(1))
    results = entries.select { |entry| entry.is_a?(Hash) && entry.dig("payload", "type") == "function_call_output" }
    assert_equal 1, results.length, "the result rides the next request: #{entries.inspect}"
    parts = entries.flat_map { |entry| Array(entry["parts"]) }
    refute(parts.any? { |part| part["type"] == "upload" }, "a non-media link places no picture: #{parts.inspect}")
    refute_match(/image content omitted: this model does not support image input/, output,
      "a non-media link renders no ruled line either")
    refute_includes output, link.fetch("uri").delete_prefix("nexus://uploads/"), "no upload id reaches the model"
  end

  # (b)6. The fallback's absence: a structure-only result is `""` on the
  # task read AND in the next round's sealed request — read through
  # `rho request`, never the body's text alone — with the structure whole.
  def test_a_structure_only_result_hands_the_model_the_empty_word_and_serves_the_structure_whole
    loop_id = rho_do("!mock tool_call=structure tool_args=#{args("path" => "x")} -- go on")
    completed = await_loop_completion(loop_id)
    task = tool_task(completed, "structure")
    key = task.fetch("key")
    detail = @steward_client.workspace(@workspace_public_id).agent_loops.agent_loop(loop_id).task(key)
    assert_equal "", detail.output, "no text: the model reads the empty word, never the entry JSON"
    assert_nil detail.content, "no text block was written"
    assert_equal({ "echo" => "structure", "arguments" => { "path" => "x" } }, detail.structured_content)

    rounds = completed.fetch("tasks").select { |row| row.fetch("kind") == "model_task" }.map { |row| row.fetch("key") }
    assert_operator rounds.length, :>=, 2, "the mock ran a round after the tool: #{rounds.inspect}"
    output, status = @daemon.cli("request", loop_id, rounds.last)
    assert_predicate status, :success?, output
    entries = JSON.parse(output.split("entries:\n", 2).fetch(1))
    # The sealed entry is a `tool_result_item` whose payload is the
    # `function_call_output` the model reads.
    results = entries.select { |entry| entry.is_a?(Hash) && entry.dig("payload", "type") == "function_call_output" }
    assert_equal 1, results.length, entries.inspect
    assert_equal "", results.first.fetch("payload").fetch("output"), "the sealed bytes hand the model the empty word"
    refute_match(/structure/, results.first.fetch("payload").fetch("output").to_s)
  end

  private

    def args(hash) = CGI.escape(JSON.generate(hash))

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # The round's captures in CALL order: the fan's keys (`rNt0`, `rNt1`
    # — the member index follows the call order) and the provider's own
    # `captured` line per key. Answers `[keys, upload ids]`.
    def captured_in_call_order(completed, loop_id)
      keys = completed.fetch("tasks").select { |row| row.fetch("kind") == "tool_task" && row["tool_name"] == "capture" }
        .map { |row| row.fetch("key") }.sort
      assert_equal 2, keys.length, "the mock called capture twice in one round: #{summarize(completed)}"
      ids = keys.map do |key|
        event = provider_event("captured", loop_id, key)
        refute_nil event, "the provider staged a capture for #{key}: #{@provider.log_text}"
        event.fetch("upload_public_id")
      end
      [keys, ids]
    end

    # The round AFTER the tool round and its sealed entries, through the
    # shipped `rho request` — the compiled bytes, never the body's text.
    def next_request_entries(completed, loop_id)
      rounds = completed.fetch("tasks").select { |row| row.fetch("kind") == "model_task" }.map { |row| row.fetch("key") }
      assert_operator rounds.length, :>=, 2, "the mock ran a round after the tool: #{rounds.inspect}"
      output, status = @daemon.cli("request", loop_id, rounds.last)
      assert_predicate status, :success?, output
      [rounds.last, JSON.parse(output.split("entries:\n", 2).fetch(1))]
    end

    # `rho do`, the shipped verb, and the id of the loop backing the turn;
    # no `--runner`: the pool serves `capture` (a provider is never a binding).
    def rho_do(prompt, model: MODEL)
      output, status = @daemon.cli("do", prompt, "--model", model, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, output
      loop_id
    end

    # The provider's own log line for ONE row: task keys repeat across loops
    # (`r2t0` in every turn), so a line is matched by loop AND key.
    def provider_event(event, loop_id, key)
      @provider.since_start.find do |line|
        line["event"] == event && line["loop"] == loop_id && line["task"] == key
      end
    end

    def tool_task(completed, name)
      task = completed.fetch("tasks").find { |row| row.fetch("kind") == "tool_task" && row["tool_name"] == name }
      refute_nil task, "the model never called #{name}: #{summarize(completed)}"
      task
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    # The bytes read, RAW: the headers a client reads (the type, the
    # Accept-Ranges) and the status under a credential of another plane.
    def bytes_response(upload_id, credential)
      uri = URI.join(@base_url, "/agent_api/v1/uploads/#{upload_id}/bytes")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{credential}"
      Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    end

    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_loop_completion(loop_id)
      latest = nil
      await("the loop never completed; last seen #{latest.inspect}") do
        latest = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/agent_loops/#{loop_id}")
        found = latest["agent_loop"]
        flunk "the loop halted: #{summarize(found)}" if found && found["status"] == "needs_attention"
        found if found && found["status"] == "completed"
      end
    end

    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        found = yield
        return found if found
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep LOOP_POLL
      end
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
