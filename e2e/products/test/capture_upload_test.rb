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
# reader of a row that names it. The world: a rho under the empty-extensions prelude (it
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
# pointers, the mock's own witness that pictures left the process, including on the next conversation
# turn; on `dev/mock-text-only` the RULED line stands in each picture's place (no part, no upload id);
# and a `.log` capture adds neither a
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
      File.write(File.join(home, "settings.json"),
        JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "rho.codemode" => { "enabled" => false } })), perm: 0o600)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home,
        env: { "RUBYOPT" => "-r#{EMPTY_PRELUDE}" })
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
        registration_identifier: PROVIDER_IDENTIFIER, runner_display_name: PROVIDER_DISPLAY_NAME,
        executor_kind: "tool_provider"
      )
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      offer = E2E::RunnerGrant.scope_offer(actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = device.await_credentials(authorization)
      @world.provider_credential = credentials.executor_access_token
      @world.provider = E2E::ExecutorProcess.new(base_url: base_url, home: @world.provider_home,
        credential: credentials.executor_access_token, kind: :tool_provider, tools: PROVIDER_TOOLS)
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
    assert_equal "tool_provider", @provider.announced_kind
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

    detail = @steward_client.workspace(@workspace_public_id).runs.run(loop_id).task(key)
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
    assert_nil @steward_client.workspace(@workspace_public_id).runs.run(orphan_loop)
      .task(orphan_key).title, "an unlinked capture commits the text alone: no title"
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

      detail = @steward_client.workspace(@workspace_public_id).runs.run(loop_id).task(key)
      assert_equal [%w[type text]], detail.content.map { |block| ["type", block.fetch("type")] },
        "the same token committed the text alone after the refusal: #{detail.content.inspect}"
      assert_nil detail.title
      assert_nil detail.metadata
    end
    io = StringIO.new
    assert_equal 200, @steward_client.uploads.bytes(users_upload.public_id, io).status, "the User's own row stays theirs"
    assert_equal PNG, io.string.b
  end

  private

    def args(hash) = CGI.escape(JSON.generate(hash))

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # `rho do`, the shipped verb, and the id of the loop backing the turn;
    # no `--runner`: the pool serves `capture` (a provider is never a binding).
    def rho_do(prompt, model: MODEL)
      output, status = @daemon.cli("do", prompt, "--model", model, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      loop_id = output[/^run:\s+(\S+)/, 1]
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
        latest = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{loop_id}")
        found = latest["run"]
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
