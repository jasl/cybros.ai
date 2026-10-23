require "test_helper"
require "base64"
require "cgi/escape"
require "fileutils"
require "net/http"
require "nokogiri"
require "securerandom"
require "stringio"
require "tmpdir"
require "zlib"
require "support/actor_provisioning"
require "support/executor_process"
require "support/mcp_fixture/declarations"
require "support/mock_llm/app"
require "support/peer_program"
require "support/runner_grant"
require "support/steward_session"

# A paired Agent declares its behavior and submits from a separate process
# which exits at the input receipt. Only Nexus and an independent Runner/MCP
# server advance the work. There is no rho application or observer-side loop.
class OfflineAgentTest < Minitest::Test
  MODEL = E2E::CatalogOverlay::MCP_MODEL
  POLL = 1
  TIMEOUT = 90
  World = Data.define(:peer, :workspace, :runner, :home, :project, :human, :operator, :connection)

  class << self
    def world(base_url)
      @world ||= begin
        human = E2E::ActorProvisioning.world(base_url).shared_human
        actor = E2E::StewardSession.actor(base_url: base_url, human: human)
        peer = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "offline-agent")
        home = Dir.mktmpdir("e2e-offline-agent")
        project = File.join(home, "project").tap { |path| FileUtils.mkdir_p(path) }
        @owned_home = home
        device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
        E2E::DeviceAuthorizationBudget.consume
        authorization = device.request_runner_authorization(
          registration_identifier: "e2e-offline-runner-#{SecureRandom.hex(4)}", runner_display_name: "Offline Agent environment")
        E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
        E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
        credentials = device.await_credentials(authorization)
        @owned_runner = E2E::ExecutorProcess.new(base_url: base_url, home: home,
          credential: credentials.executor_access_token, world: project, environment: project).start
        E2E.enable_dev_lane!
        E2E.hosts.start
        workspace = peer.client.workspace(peer.client.workspaces.create(
          name: "Offline Agent", idempotency_key: SecureRandom.uuid).workspace.public_id)

        E2E::SessionSignInBudget.consume
        session = CybrosAgent::Platform::Sessions.new(base_url: base_url).create(email: human.email, password: human.password)
        E2E::SecretHygiene.register(session.token)
        @owned_operator = CybrosAgent::PlatformClient.new(base_url: base_url, credential: session.token)
        connection = @owned_operator.mcp_connections.create(name: "Offline service",
          endpoint_url: E2E.handle.fetch("mcp_fixture_url"), auth_type: "none")
        @owned_connection = connection.public_id
        connection = @owned_operator.mcp_connections.refresh_catalog(connection.public_id, lock_version: connection.lock_version)
        World.new(peer: peer, workspace: workspace, runner: @owned_runner, home: home, project: project,
          human: human, operator: @owned_operator, connection: connection)
      end
    end

    def close
      if @owned_connection
        connection = @owned_operator.mcp_connections.fetch(@owned_connection)
        @owned_operator.mcp_connections.update(connection.public_id, lock_version: connection.lock_version, enabled: false)
      end
      @owned_operator&.session&.revoke
    ensure
      @owned_runner&.stop
      FileUtils.remove_entry(@owned_home) if @owned_home && File.directory?(@owned_home)
    end
  end

  Minitest.after_run { OfflineAgentTest.close }

  def setup
    @runs = []
    @base_url = E2E.base_url(mcp_fixture: true)
    @world = self.class.world(@base_url)
    @peer = @world.peer
    @workspace = @world.workspace
    @human = CybrosAgent::Client.new(base_url: @base_url, credential: @world.human.member_token)
  end

  def teardown
    @runs.each do |run|
      run.stop(force: true) if run.fetch.status == "running"
    end
    warn E2E::SecretHygiene.redact(@world.runner.log_text) if !passed? && @world
  end

  def test_runner_and_direct_mcp_continue_for_multiple_rounds_after_the_submitter_exits
    marker = "runner-result-#{SecureRandom.hex(8)}"
    File.write(File.join(@world.project, "offline.txt"), marker)
    declaration = declaration(mcp_tools: [{ "connection_public_id" => @world.connection.public_id,
      "tool_name" => "echo", "name" => "cloud_echo" }])
    chat = conversation
    receipt, materialization, run = submit(chat, script(
      ["bash", { "command" => "sleep 5; printf first-round" }],
      ["read", { "path" => "offline.txt" }], ["cloud_echo", { "text" => "after the Runner" }]), declaration: declaration)
    assert_running_after_exit(run)
    held = await("the Runner to claim work after the submitter exited") do
      run.fetch.tasks.find { |task| task.tool_name == "bash" && task.claimed_by }
    end
    assert_equal "dispatched", held.status, "the independent Runner is still executing the first call"
    continuation = run.fetch.tasks.find { |task| task.key == "r2" }
    refute_nil continuation
    assert_equal "waiting", continuation.status
    assert_nil continuation.started_at, "the first tool holds the continuation after the submitter exited"

    completed = complete(run)
    assert_equal %w[r1 r2 r3 r4], completed.tasks.select(&:model_task?).map(&:key)
    tool_rows = completed.tasks.select(&:tool_call?)
    assert_equal %w[bash read echo], tool_rows.map(&:tool_name)
    assert_equal "cloud_echo", tool_rows.last.tool_alias
    assert_equal @world.connection.public_id, tool_rows.last.target.connection_public_id
    assert tool_rows.first(2).all? { |task| task.claimed_by&.executor_public_id == @world.runner.executor_public_id }
    assert_nil tool_rows.last.claimed_by, "Nexus called its MCP connection directly"
    assert_includes task_text(run, tool_rows[1].key), marker
    assert_includes task_text(run, tool_rows.last.key), "#{E2E::McpFixture::ECHO_TEXT_PREFIX}after the Runner"
    final = completed_turn(chat, materialization.turn_public_id)
    assert_includes final.text, marker
    assert_includes final.text, E2E::McpFixture::ECHO_TEXT_PREFIX

    reconnect = CybrosAgent::Client.new(base_url: @base_url, credential: @peer.credential)
    recovered_chat = reconnect.workspace(@workspace.public_id).conversation(chat.public_id)
    recovered = recovered_chat.inputs.materialization(receipt)
    assert_equal materialization.to_h, recovered.to_h
    assert_equal final.text, recovered_chat.turns.fetch(recovered.turn_public_id).text
    assert_equal completed.tasks.map(&:key), reconnect.workspace(@workspace.public_id).run(recovered.run_public_id).fetch.tasks.map(&:key)
    assert_equal 1, recovered_chat.turns.list.items.count { |turn| turn.input_public_id == receipt },
      "reconnecting only reads the original reply"
    exact = recovered_chat.turns.variant(recovered.turn_public_id, recovered.variant_public_id)
    assert_equal recovered.variant_public_id, exact.variant.public_id
    analysis = reconnect.work.analysis(workspace_public_id: @workspace.public_id,
      from: (Time.now.utc - 3600).iso8601(6), to: (Time.now.utc + 60).iso8601(6), group_by: "provider_id")
    assert_equal @workspace.public_id, analysis.workspace_public_id
    assert_operator analysis.execution.run_count, :>=, 1
    assert_operator analysis.execution.tools.task_count, :>=, 3
    assert_operator analysis.model_usage.totals.request_count, :>=, 4
  end

  def test_human_approval_and_question_remain_durable_without_an_application_listener
    declaration = declaration(kernel_tools: ["nexus.human.ask"], approval_mode: "ask")
    chat = conversation
    _receipt, materialization, run = submit(chat, script(
      ["bash", { "command" => "printf approved-by-human" }],
      ["ask", { "prompt" => "Which destination should receive the result?" }]), declaration: declaration)
    assert_running_after_exit(run)
    approval = await("the actual Runner call to require approval") do
      run.fetch.tasks.find { |task| task.status == "needs_approval" }
    end
    assert_equal "bash", approval.tool_name
    assert_nil approval.claimed_by, "no Runner can execute an unapproved command"
    human_run = @human.workspace(@workspace.public_id).run(run.run_public_id)
    human_run.tasks_context(approval.key).approve
    decided = run.task(approval.key)
    assert_equal "human", decided.task.approval.fetch("origin")

    ask = await("the question tool's approval") do
      run.fetch.tasks.find { |task| task.tool_name == "ask" && task.status == "needs_approval" }
    end
    human_run.tasks_context(ask.key).approve
    question = await("the kernel-held question") do
      run.fetch.tasks.find { |task| task.await? && task.status == "awaiting_input" }
    end
    assert_equal "running", run.fetch.status
    assert_equal "awaiting_input", human_run.task(question.key).task.status
    human_run.tasks_context(question.key).resolve(content: "The shared archive")
    completed = complete(run)
    assert_equal 3, completed.tasks.count(&:model_task?)
    final = completed_turn(chat, materialization.turn_public_id)
    assert_includes final.text, "approved-by-human"
    assert_includes final.text, "The shared archive"
  end

  def test_sdk_attachments_reach_the_exact_human_session_task_result_download
    named = @peer.client.profile.agents.declare(name: "files-#{SecureRandom.hex(4)}", scope: "instance",
      description: "Generate an image from a Human's attached request.",
      configuration: declaration(kernel_tools: ["nexus.image.generate"], image_model: "dev/mock-image"))
    chat = conversation(answering_user_public_id: named.public_id)
    actor = E2E::StewardSession.actor(base_url: @base_url, human: @world.human)
    actor.visit("/conversations/#{chat.public_id}")
    original_bytes = "Human attachment #{SecureRandom.hex(8)}\n"
    uploaded = @human.uploads.create_io(StringIO.new(original_bytes), filename: "request.txt")
    upload_id = uploaded.public_id
    assert_equal ["request.txt", "application/octet-stream", original_bytes.bytesize],
      [uploaded.filename, uploaded.content_type, uploaded.byte_size]
    original = human_session_request(actor, Net::HTTP::Get, "/uploads/#{upload_id}/bytes")
    assert_equal "200", original.code, original.body
    assert_equal original_bytes, original.body

    human_chat = @human.workspace(@workspace.public_id).conversation(chat.public_id)
    accepted = human_chat.inputs.create(kind: "direct_reply",
      text: script(["image_generate", { "prompt" => "Draw an attached request's red square" }]),
      model: MODEL, idempotency_key: SecureRandom.uuid, attachments: [upload_id])
    input_id = accepted.public_id
    accepted_path = "/conversations/#{chat.public_id}/inputs/#{input_id}"
    materialization = await("the Human input's exact materialization") { chat.inputs.materialization(input_id) }
    refute_nil materialization.run_public_id
    run = @workspace.run(materialization.run_public_id)
    @runs << run
    completed = complete(run)
    turn = completed_turn(chat, materialization.turn_public_id)
    assert_equal input_id, turn.input_public_id
    variant = chat.turns.variant(materialization.turn_public_id, materialization.variant_public_id).variant
    assert_equal [upload_id], variant.attachments.map(&:public_id)

    followed = human_session_request(actor, Net::HTTP::Get, accepted_path)
    assert_equal "200", followed.code, followed.body
    assert Nokogiri::HTML5.parse(followed.body).at_css("a[href='/uploads/#{upload_id}/bytes']"),
      "the original input's retained attachment remains downloadable after materialization"
    generated = completed.tasks.find { |task| task.model_task? && task.workload == "image_generation" }
    refute_nil generated
    assert_equal "completed", generated.status
    result = human_session_request(actor, Net::HTTP::Get, "/runs/#{run.run_public_id}/tasks/#{generated.key}")
    assert_equal "200", result.code, result.body
    downloads = Nokogiri::HTML5.parse(result.body).css("a[href^='/uploads/'][href$='/bytes']")
    assert_equal 1, downloads.length, "the exact image Task lists its one bound result"
    output_link = run.task(generated.key).content.find { |part| part["type"] == "resource_link" }
    refute_nil output_link
    output_id = output_link.fetch("uri").delete_prefix("nexus://uploads/")
    assert_equal "/uploads/#{output_id}/bytes", downloads.first["href"]
    bytes = human_session_request(actor, Net::HTTP::Get, downloads.first["href"])
    assert_equal "200", bytes.code, bytes.body
    assert_equal "image/png", bytes["Content-Type"]
    assert_equal Base64.strict_decode64(E2E::MockLLM::App::PIXEL_PNG), bytes.body.b
  end

  def test_a_kernel_restart_does_not_repeat_an_mcp_write_whose_response_was_lost
    marker = "lost-mcp-response-#{SecureRandom.hex(8)}"
    fixture_write("hold", marker)
    held = true
    chat = conversation
    # A branch is submitted before the seed starts, so its review round does
    # not try to read a still-live mainline while the input is materialized.
    receipt, tracking, run = submit_tracked(chat, "!mock reply=accepted -- Prepare the recorded external write",
      declaration: declaration, steps: [{ "parallel" => [[
        { "tool" => { "key" => "external-write", "name" => "write",
          "route" => { "kind" => "mcp", "connection_public_id" => @world.connection.public_id },
          "input" => { "text" => marker }, "timeout_ms" => 20_000, "on_failure" => "halt" } },
        { "model" => { "key" => "after-review", "model" => { "model" => MODEL },
          "prompt" => "!mock reply=reviewed-without-repeating -- Report that the uncertain write was reviewed" } },
      ]] }])
    original = tracking.result
    assert_running_after_exit(run)
    await("the MCP service to record its effect and hold the response") do
      fixture_writes(marker) == { "count" => 1, "waiting" => 1 }
    end
    assert_equal "running", run.task("external-write").task.status

    E2E.hosts.stop
    assert_equal({ "count" => 1, "waiting" => 1 }, fixture_writes(marker),
      "the request reached the external service before its kernel caller died")
    fixture_write("release", marker)
    held = false
    await("the service to finish the response after its caller died") { fixture_writes(marker).fetch("waiting").zero? }
    reconnect = CybrosAgent::Client.new(base_url: @base_url, credential: @peer.credential)
    recovered_chat = reconnect.workspace(@workspace.public_id).conversation(chat.public_id)
    recovered = recovered_chat.input_execution(receipt)
    assert_equal original, recovered.refresh.result
    assert_equal original, recovered.recover.execution

    E2E.hosts.start
    attention = await("the original MCP task to require adjudication after restart", poll: 3) do
      snapshot = recovered.recover
      snapshot if snapshot&.needs_attention?
    end
    assert_equal original, attention.execution
    uncertain = run.task("external-write").task
    assert_equal "uncertain", uncertain.status
    assert_equal "tool_uncertain", uncertain.error.fetch("key")
    assert_equal @world.connection.public_id, uncertain.target.connection_public_id
    assert_equal({ "count" => 1, "waiting" => 0 }, fixture_writes(marker),
      "restart must not resubmit a call whose external effect may already exist")

    @human.workspace(@workspace.public_id).run(original.run_public_id).tasks_context("external-write").abandon
    completed = await("the reviewed execution's original final reply", poll: 3) do
      snapshot = recovered.recover
      snapshot if snapshot&.terminal?
    end
    assert_equal "completed", completed.status
    assert_equal original, completed.execution
    assert_includes completed.content, "reviewed-without-repeating"
    assert_equal 1, fixture_writes(marker).fetch("count")
    assert_equal "uncertain", run.task("external-write").task.status,
      "abandon records a decision without pretending the external outcome became known"
  ensure
    fixture_write("release", marker) if held
    E2E.hosts.start
  end

  def test_a_published_image_and_its_continuation_survive_a_kernel_restart
    marker = "image-restart-#{SecureRandom.hex(8)}"
    release = File.join(@world.project, "#{marker}.release")
    command = "deadline=$((SECONDS + 60)); until test -f #{File.basename(release)}; do " \
      "test $SECONDS -ge $deadline && exit 1; sleep 0.1; done; printf #{marker}"
    chat = conversation
    receipt, tracking, run = submit_tracked(chat, script(
      ["image_generate", { "prompt" => "Draw a red square to retain across the restart" }],
      ["bash", { "command" => command }]),
      declaration: declaration(kernel_tools: ["nexus.image.generate"], image_model: "dev/mock-image"))
    original = tracking.result
    assert_running_after_exit(run)
    await("the independent Runner to hold the continuation after image publication") do
      run.fetch.tasks.find { |task| task.tool_name == "bash" && task.claimed_by && task.status == "dispatched" }
    end
    image_task = run.fetch.tasks.find { |task| task.model_task? && task.workload == "image_generation" }
    refute_nil image_task
    assert_equal "completed", image_task.status
    links = run.task(image_task.key).content.select { |part| part["type"] == "resource_link" }
    assert_equal 1, links.length
    upload_id = links.first.fetch("uri").delete_prefix("nexus://uploads/")
    assert_equal "running", run.fetch.status

    E2E.hosts.stop
    reconnect = CybrosAgent::Client.new(base_url: @base_url, credential: @peer.credential)
    recovered_chat = reconnect.workspace(@workspace.public_id).conversation(chat.public_id)
    recovered = recovered_chat.input_execution(receipt)
    snapshot = recovered.recover
    assert_equal original, snapshot.execution
    refute_predicate snapshot, :terminal?
    upload = reconnect.uploads.fetch(upload_id)
    bytes = StringIO.new
    reconnect.uploads.bytes(upload_id, bytes)
    assert_equal "image/png", upload.content_type
    assert_equal upload.byte_size, bytes.string.bytesize
    assert bytes.string.b.start_with?("\x89PNG".b)

    E2E.hosts.start
    File.write(release, "continue")
    completed = await("the original image reply to finish after kernel restart", poll: 3) do
      current = recovered.recover
      current if current&.terminal?
    end
    assert_equal "completed", completed.status
    assert_equal original, completed.execution
    assert_includes completed.content, marker
    images = run.fetch.tasks.select { |task| task.model_task? && task.workload == "image_generation" }
    assert_equal [image_task.key], images.map(&:key)
    assert_equal links, run.task(image_task.key).content.select { |part| part["type"] == "resource_link" }
    assert_includes JSON.generate(run.tasks_context("r3").request.entries), upload_id
    assert_equal 1, recovered_chat.turns.list.items.count { |turn| turn.input_public_id == receipt }
  ensure
    File.write(release, "continue") if release
    E2E.hosts.start
  end

  def test_a_conversation_cost_limit_preserves_the_checkpoint_until_explicit_task_retry
    marker = "cost-checkpoint-#{SecureRandom.hex(8)}"
    # Counting is opt-in on the external fixture. Release immediately so this
    # case records each write without exercising the lost-response hold.
    fixture_write("hold", marker)
    fixture_write("release", marker)
    chat = conversation(cost_limit: "0")
    receipt, tracking, run = submit_tracked(chat, "!mock reply=accepted -- Complete the recorded workflow",
      declaration: declaration, steps: [{ "parallel" => [[
        { "tool" => { "key" => "write-once", "name" => "write",
          "route" => { "kind" => "mcp", "connection_public_id" => @world.connection.public_id },
          "input" => { "text" => marker }, "on_failure" => "halt" } },
        { "model" => { "key" => "priced-review", "model" => { "model" => "dev/mock-priced" },
          "prompt" => "!mock reply=reviewed usage=2:1 -- Review the completed write", "on_failure" => "propagate" } },
        { "model" => { "key" => "after-review", "model" => { "model" => MODEL },
          "prompt" => "!mock reply=checkpoint-recovered -- Report the completed review" } },
      ]] }])
    original = tracking.result
    held = await("the priced model task to hold its original execution") do
      snapshot = tracking.recover
      snapshot if snapshot&.needs_attention?
    end
    assert_equal original, held.execution
    assert_equal "completed", run.task("write-once").task.status
    assert_equal 1, fixture_writes(marker).fetch("count")
    refused = run.task("priced-review").task
    assert_equal "failed", refused.status
    assert_equal "conversation_cost_limit_reached", refused.error.fetch("key")
    assert_equal "propagate", refused.on_failure, "the declaration stays frozen while the refusal holds for repair"
    dependent = run.task("after-review").task
    assert_equal "waiting", dependent.status, "the refusal must not skip the dependent task"
    assert_nil dependent.started_at
    limited = chat.fetch
    assert limited.cost_limit_reached
    assert_equal "USD", limited.usage_summary.cost_unit, "the public first-owner setup configured the pricing unit"
    assert_equal 1, limited.usage_summary.request_count, "only the free opening round produced a receipt"

    retried = run.tasks_context("priced-review").retry
    assert_equal "waiting", retried.status, "the retry receipt proves the previous failure was cleared"
    assert_nil retried.error
    held_again = await("the unchanged cost limit to refuse the retried task") do
      snapshot = tracking.recover
      snapshot if snapshot&.needs_attention?
    end
    assert_equal original, held_again.execution
    assert_equal "conversation_cost_limit_reached", run.task("priced-review").task.error.fetch("key")
    assert_equal "waiting", run.task("after-review").task.status
    assert_equal 1, fixture_writes(marker).fetch("count")
    limited = chat.fetch
    assert_equal 1, limited.usage_summary.request_count, "retry before adjustment still creates no priced receipt"

    changed = chat.update(lock_version: limited.lock_version, cost_limit: "1")
    refute changed.cost_limit_reached
    assert_equal "needs_attention", run.fetch.status, "changing the cap does not restart accepted work"
    run.tasks_context("priced-review").retry
    completed = complete(run)
    %w[write-once priced-review after-review].each do |key|
      assert_equal "completed", completed.tasks.find { |task| task.key == key }.status
    end
    assert_equal 1, fixture_writes(marker).fetch("count"), "retry must not repeat the completed external write"
    assert_equal original, tracking.refresh.result, "Run, Turn and Variant identities survive repair"
    assert_equal original, tracking.recover.execution
    assert_equal receipt, completed_turn(chat, original.turn).input_public_id
    assert_equal "0.0000025", chat.fetch.usage_summary.cost_amount,
      "the resumed priced attempt settles through the ordinary conversation ledger"
  end

  private

    def declaration(**overrides)
      {
        "default_model" => MODEL, "prompt_mechanism" => "default", "approval_mode" => "bypass",
        "tool_definitions" => [], "kernel_tools" => [], "mcp_tools" => [],
        "runner_executor_public_ids" => [@world.runner.executor_public_id], "runner_tool_names" => %w[bash read],
        "compaction_policy" => { "mode" => "off" },
      }.merge(overrides.transform_keys(&:to_s))
    end

    def conversation(**fields)
      @workspace.conversation(@workspace.conversations.create(default_runner_executor_public_id: @world.runner.executor_public_id,
        memory_context: { "bindings" => [] }, idempotency_key: SecureRandom.uuid, **fields).public_id)
    end

    def submit(chat, prompt, declaration: nil)
      receipt = submit_input(chat, prompt, declaration: declaration)
      materialization = await("the accepted input's original materialization") { chat.inputs.materialization(receipt) }
      assert_equal receipt, chat.turns.fetch(materialization.turn_public_id).input_public_id
      refute_nil materialization.run_public_id
      run = @workspace.run(materialization.run_public_id)
      @runs << run
      [receipt, materialization, run]
    end

    def submit_tracked(chat, prompt, declaration:, **fields)
      receipt = submit_input(chat, prompt, declaration: declaration, **fields)
      tracking = chat.input_execution(receipt)
      original = await("the accepted input's original execution") do
        tracking.refresh
        flunk "input was blocked: #{tracking.blocked_reason}" if tracking.blocked_reason
        tracking.result
      end
      assert_equal receipt, chat.turns.fetch(original.turn).input_public_id
      refute_nil original.run_public_id
      run = @workspace.run(original.run_public_id)
      @runs << run
      [receipt, tracking, run]
    end

    def submit_input(chat, prompt, declaration:, **fields)
      fields[:agent_configuration] = declaration if declaration
      @peer.submit_and_exit(base_url: @base_url, workspace_public_id: @workspace.public_id,
        conversation_public_id: chat.public_id, kind: "direct_reply", text: prompt, model: MODEL,
        idempotency_key: SecureRandom.uuid, **fields)
    end

    # The existing signed-in browser supplies the cookie and CSRF context.
    # These public HTTP reads/writes exercise the Session doors without an
    # Agent bearer or an extra sign-in/world, and preserve redirects as receipts.
    def human_session_request(actor, verb, path)
      uri = URI.join(@base_url, path)
      request = verb.new(uri)
      request["Cookie"] = actor.page.driver.browser.manage.all_cookies.map { |cookie|
        "#{cookie.fetch(:name)}=#{cookie.fetch(:value)}"
      }.join("; ")
      request["Origin"] = @base_url
      request["X-CSRF-Token"] = actor.page.find("meta[name='csrf-token']", visible: false)["content"]
      yield request if block_given?
      Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
    end

    def fixture_write(action, marker)
      fixture_request(Net::HTTP::Post, "/fixture/writes/#{action}", body: { "text" => marker })
    end

    def fixture_writes(marker)
      fixture_request(Net::HTTP::Get, "/fixture/writes?#{URI.encode_www_form(text: marker)}")
    end

    def fixture_request(verb, path, body: nil)
      uri = URI.join(E2E.handle.fetch("mcp_fixture_url"), path)
      request = verb.new(uri)
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) { |http| http.request(request) }
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end

    def assert_running_after_exit(run)
      assert_equal "running", run.fetch.status, "the SDK process exited before execution completed"
    end

    def script(*calls, usage: nil)
      encoded = calls.map { |name, args| "#{name}:#{CGI.escape(JSON.generate(args))}" }.join(",")
      "!mock echo=content#{" usage=#{usage}" if usage} tool_call=#{encoded} -- Report the returned results"
    end

    def task_text(run, key)
      detail = run.task(key)
      detail.output || detail.content.to_a.filter_map { |part| part["text"] }.join("\n")
    end

    def complete(run)
      await("the run to complete without an application") do
        row = run.fetch
        flunk "run failed: #{row.to_h.inspect}" if %w[failed stopped canceled].include?(row.status)
        row if row.status == "completed"
      end
    end

    def completed_turn(chat, public_id)
      await("the accepted input's final reply") do
        turn = chat.turns.fetch(public_id)
        flunk "turn failed: #{turn.to_h.inspect}" if %w[failed canceled].include?(turn.status)
        turn if turn.status == "completed"
      end
    end

    def await(message, poll: POLL)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
      loop do
        answer = yield
        return answer if answer
        flunk "Timed out waiting for #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep poll
      end
    end
end
