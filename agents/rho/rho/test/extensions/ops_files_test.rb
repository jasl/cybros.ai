require_relative "../test_helper"
require_relative "../support/ops_harness"

# Local file reads and requests relayed through an external Runner.
class OpsFilesTest < Minitest::Test
  include RhoTest::OpsHarness

  # THE PAGE'S READER OF WHAT A TOOL WROTE, this machine's
  # half: `/files/bytes` resolves against the root the tools are pointed
  # at, through the runner gem's own `Files`, under THIS daemon's policy
  # header — and an honest refusal when there is no root yet.
  def test_files_bytes_reads_this_machines_own_disk_under_the_daemons_policy
    root = File.join(@root, "src")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "note.txt"), "hello")
    daemon = boot(config: agent_mode("tools_root" => root))

    response = request(daemon, :get, "/files/bytes?path=note.txt", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal "hello", response.body
    assert_includes response["content-type"], "text/plain"
    assert_includes response["content-security-policy"], "default-src 'none'"
    assert_includes response["content-security-policy"], "sandbox"
    assert_equal "nosniff", response["x-content-type-options"]
    assert_equal "404", request(daemon, :get, "/files/bytes?path=gone.txt", token: bearer(daemon)).code
    assert_equal "401", request(daemon, :get, "/files/bytes?path=note.txt").code

    nowhere = boot(root: Dir.mktmpdir("rho-ops-nowhere"))
    refused = request(nowhere, :get, "/files/bytes?path=note.txt", token: bearer(nowhere))
    assert_equal "409", refused.code
    assert_equal "environment_unset", JSON.parse(refused.body).dig("error", "code")
  end

  # WHERE THE FILE IS, PER CONVERSATION:
  # `host` naming a followed conversation on this machine's own runner
  # reads under THAT conversation's root — its record in the store — and
  # the default root when it has none.
  def test_files_bytes_reads_under_the_named_conversations_root
    default = File.join(@root, "default")
    project = File.join(@root, "project")
    FileUtils.mkdir_p(default)
    FileUtils.mkdir_p(project)
    File.write(File.join(default, "note.txt"), "default")
    File.write(File.join(project, "note.txt"), "project")
    api = NexusDoubles::FakeAgentApi.new
    api.stock_store_entry("c-1", namespace: "rho.environment", key: "binding/0199-runner",
      value: { "root" => project, "directories" => [], "anchor" => "c-1" })
    daemon = member_ready(boot(config: agent_mode("tools_root" => default)), api, identity: RUNNER_IDENTITY)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", runner: "0199-runner")
    store.remember(Rho::Host::Conversation.new(public_id: "c-2"), workspace: "ws-1", runner: "0199-runner")

    assert_equal "project", request(daemon, :get, "/files/bytes?path=note.txt&host=c-1", token: bearer(daemon)).body
    assert_equal "default", request(daemon, :get, "/files/bytes?path=note.txt&host=c-2", token: bearer(daemon)).body
    assert_equal "default", request(daemon, :get, "/files/bytes?path=note.txt", token: bearer(daemon)).body
  end

  # The other half: `host` names a followed host whose runner is not this
  # process, so the file is read THERE — `files_bytes` relayed through
  # `Ops.call_tool`, the capture it names fetched on the member plane and
  # streamed back under the same headers; a host on this daemon's own
  # runner reads from disk with no run.
  def test_files_bytes_reads_a_remote_runners_file_through_files_bytes_and_streams_the_capture
    root = File.join(@root, "src")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "note.txt"), "hello")
    api = NexusDoubles::FakeAgentApi.new(
      task_detail: { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "files_bytes",
                     "output" => "/there/shot.png (image/png, 4 bytes)",
                     "content" => [{ "type" => "text", "text" => "/there/shot.png (image/png, 4 bytes)" },
                                   { "type" => "resource_link", "uri" => "nexus://uploads/up-1", "name" => "shot.png",
                                     "mimeType" => "image/png", "size" => 4 }],
                     "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z" },
      upload_bytes: { "up-1" => "PNG!" }
    )
    daemon = member_ready(boot(config: agent_mode("tools_root" => root)), api, identity: RUNNER_IDENTITY)
    store.remember(Rho::Host::Run.new(public_id: "al-9"), workspace: "ws-1", runner: "0199-h")
    store.remember(Rho::Host::Run.new(public_id: "al-2"), workspace: "ws-1", runner: "0199-runner")

    response = request(daemon, :get, "/files/bytes?path=/there/shot.png&host=al-9", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal "PNG!", response.body
    assert_equal "image/png", response["content-type"]
    assert_match(/\Ainline; filename="shot\.png"/, response["content-disposition"])
    assert_includes response["content-security-policy"], "default-src 'none'"
    assert_equal [{ "name" => "files_bytes", "input" => { "path" => "/there/shot.png" }, "key" => "call_tool",
                    "timeout_ms" => Rho::Extensions::Ops::Files::RELAY_TIMEOUT_MS,
                    "route" => { "kind" => "runner", "runner_executor_public_id" => "0199-h" } }],
      api.run_creates.map { |body| body.dig("run", "steps", 0, "tool") }
    assert_equal "0199-h", api.run_creates.first.dig("run", "default_runner_executor_public_id")

    own = request(daemon, :get, "/files/bytes?path=note.txt&host=al-2", token: bearer(daemon))
    assert_equal "200", own.code, own.body
    assert_equal "hello", own.body
    assert_equal 1, api.run_creates.length, "this daemon's own runner reads from disk: no run"
  end

  # THE RELAY ROUTE: `POST /runs/call_tool` is the SDK's
  # composition behind the daemon's credential — ONE tool step under `raw`
  # on the runner the body names, the rules `rho do` authors RE-ADDRESSED
  # to the seed's own `author` origin (a kernel rule addresses the writer
  # its `origin` names; unnamed is the model's), the run STARTED, the task
  # polled to terminal and answered whole. A completed request leaves its
  # run alone and follows nothing: `rho runs` lists this daemon's runs,
  # and a request is not one.
  def test_the_relay_route_authors_a_one_task_run_on_the_named_runner_starts_it_and_answers_the_task
    detail = { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "capture",
               "output" => "echo:capture:{}", "on_failure" => "propagate", "visibility" => "visible",
               "content" => [{ "type" => "text", "text" => "echo:capture:{}" },
                             { "type" => "resource_link", "uri" => "nexus://uploads/up-1", "name" => "square.png",
                               "mimeType" => "image/png", "size" => 69 }],
               "title" => "capture", "metadata" => { "checkpoint" => { "step" => 1 } },
               "structured_content" => { "applied" => true, "resolved" => false },
               "claimed_by" => { "executor_public_id" => "0199-runner" },
               "created_at" => "2026-09-13T00:00:00Z" }
    api = NexusDoubles::FakeAgentApi.new(task_detail: detail)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/call_tool", token: bearer(daemon),
      body: { "runner_executor_public_id" => "0199-runner", "tool" => "capture", "input" => { "note" => "one" },
              "timeout_ms" => 5_000 })

    assert_equal "200", response.code, response.body
    answer = JSON.parse(response.body).fetch("call_tool")
    assert_equal "al-1", answer.fetch("public_id")
    task = answer.fetch("task")
    assert_equal "call_tool", task.fetch("key")
    assert_equal "completed", task.fetch("status")
    assert_equal "capture", task.fetch("title")
    assert_equal({ "checkpoint" => { "step" => 1 } }, task.fetch("metadata"))
    assert_equal "resource_link", task.fetch("content").last.fetch("type")
    # The tool's structured answer rides the row (`rho-dev call_tool R environment_bind` reads a binding back as `{applied, resolved, booted_at}`), beside the blocks a person reads.
    assert_equal({ "applied" => true, "resolved" => false }, task.fetch("structured_content"))

    authored = api.run_creates.fetch(0).fetch("run")
    assert_equal %w[steps prompt_mechanism approval_mode approval_rules default_runner_executor_public_id].sort, authored.keys.sort
    assert_equal [{ "tool" => { "name" => "capture", "input" => { "note" => "one" }, "key" => "call_tool", "timeout_ms" => 5_000,
      "route" => { "kind" => "runner", "runner_executor_public_id" => "0199-runner" } } }],
      authored.fetch("steps"), "one tool step, the deliverable by construction"
    assert_equal "raw", authored.fetch("prompt_mechanism")
    assert_equal "bypass", authored.fetch("approval_mode")
    assert_equal "0199-runner", authored.fetch("default_runner_executor_public_id")
    rules = authored.fetch("approval_rules")
    assert_equal Rho::RunDeclaration.request_rules(roots: Rho.protected_roots(daemon.home)), rules
    assert(rules.all? { |rule| rule.fetch("origin") == "author" }, "every rule re-addressed to the seed's origin")
    assert_equal Rho::RunDeclaration.approval_rules(roots: Rho.protected_roots(daemon.home)),
      rules.map { |rule| rule.except("origin") }, "the same list `rho do` authors, rule for rule"
    assert(rules.any? { |rule| rule["match"] == "*rm -?? /" && rule["verdict"] == "deny" })
    paths = api.requests.map(&:first)
    assert(paths.any? { |path| path.end_with?("/runs/al-1/start") }, "created AND started")
    refute(paths.any? { |path| path.end_with?("/runs/al-1/stop") }, "a completed request leaves its run alone")
    assert_empty JSON.parse(request(daemon, :get, "/followers", token: bearer(daemon)).body).fetch("followers"),
      "never remembered: a request is not a run this daemon follows"
  end

  # A request that did not complete answers its terminal task — the error
  # the person reads — and the composition STOPS the run behind it.
  def test_the_relay_route_answers_a_failed_request_and_stops_the_run_behind_it
    detail = { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed", "tool_name" => "nosuch",
               "error" => { "key" => "tool_not_served", "detail" => "nobody announces nosuch" },
               "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z" }
    api = NexusDoubles::FakeAgentApi.new(task_detail: detail)
    daemon = member_ready(boot, api)

    response = request(daemon, :post, "/runs/call_tool", token: bearer(daemon),
      body: { "runner_executor_public_id" => "0199-runner", "tool" => "nosuch" })

    assert_equal "200", response.code, response.body
    task = JSON.parse(response.body).dig("call_tool", "task")
    assert_equal "failed", task.fetch("status")
    assert_equal "tool_not_served", task.dig("error", "key")
    assert(api.requests.map(&:first).any? { |path| path.end_with?("/runs/al-1/stop") }, "stopped behind the failure")
    refute api.run_creates.fetch(0).dig("run", "steps", 0, "tool").key?("timeout_ms"),
      "no --timeout: the runner's announced park, else the kernel default, stands"
  end

  def test_the_relay_route_needs_a_tool_a_runner_and_an_object_input
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new)

    bare = request(daemon, :post, "/runs/call_tool", token: bearer(daemon), body: { "runner_executor_public_id" => "r" })
    assert_equal "400", bare.code
    no_runner = request(daemon, :post, "/runs/call_tool", token: bearer(daemon), body: { "tool" => "read" })
    assert_equal "400", no_runner.code, no_runner.body
    assert_match(/runner_executor_public_id is required/, JSON.parse(no_runner.body).dig("error", "message"))
    scalar = request(daemon, :post, "/runs/call_tool", token: bearer(daemon),
      body: { "runner_executor_public_id" => "r", "tool" => "read", "input" => "x" })
    assert_equal "400", scalar.code
    clock = request(daemon, :post, "/runs/call_tool", token: bearer(daemon),
      body: { "runner_executor_public_id" => "r", "tool" => "read", "timeout_ms" => "soon" })
    assert_equal "400", clock.code
  end
end
