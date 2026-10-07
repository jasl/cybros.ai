require "test_helper"
require "tempfile"
require "net/http"

# `Rho::Core` as a library: every primitive over scripted daemons — and a
# real one where the primitive needs a ceremony — answers a document or
# raises `Rho::Error` with the daemon's sentence, and prints nothing (the
# core has no `out`). `cli/terminal_test.rb` is what the LINES look like;
# rho-dev's `dev_watch_test.rb` the watch composition over these.
class CoreTest < Minitest::Test
  include RhoTest::CliHarness

  IDS = { "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
          "run" => { "public_id" => "al-9" } }.freeze

  def body_of(request) = JSON.parse(request.partition("\r\n\r\n").last)

  # ---- the conversation primitives ----

  # THE 201 DOCUMENT, WHOLE AND UNPRINTED: the ids, the tool selection, the fold an
  # extension's flags put on the body — as the daemon answered them.
  def test_open_conversation_posts_the_body_and_answers_the_201_document_unprinted
    seen = []
    document = IDS.merge("adaptations" => { "row" => "default", "source" => "gem" },
      "until" => { "command" => "make test", "attempts" => 3, "directory" => "/srv/app" })
    announce(endpoint: recording_endpoint(seen, 201, document))

    answer = core.open_conversation(prompt: "fix it", model: "m/x", directory: "/srv/app") do |body|
      body.merge("until" => { "command" => "make test", "attempts" => 3 })
    end

    assert_equal document, answer
    sent = seen.grep(%r{\APOST /conversations }).first
    refute_nil sent
    # `directory:` BINDS: the root
    # rides as the descriptive `working_directory` AND as the environment.
    assert_equal({ "prompt" => "fix it", "working_directory" => "/srv/app", "model" => "m/x",
                   "environment" => { "root" => "/srv/app", "directories" => [] },
                   "until" => { "command" => "make test", "attempts" => 3 } }, body_of(sent))
    refute core.respond_to?(:out), "the core prints nothing: it has no printer"
    assert_equal "", @out.string
  end

  # No flag sends no field: the daemon's settings decide the model, the
  # tool selection, the runner, the answerer and the access default; each named one
  # rides as itself.
  def test_open_conversation_sends_only_what_was_named
    seen = []
    announce(endpoint: recording_endpoint(seen, 201, IDS))

    core.open_conversation(prompt: "fix it")
    sent = body_of(seen.grep(%r{\APOST /conversations }).last)
    assert_equal %w[prompt working_directory], sent.keys.sort
    assert_equal Dir.pwd, sent.fetch("working_directory"), "the shell's directory is the default"

    core.open_conversation(prompt: "fix it", model: "m/x", runner: "0199-r", agent: "@lark", restricted: true,
      instructions: "be brief")
    sent = body_of(seen.grep(%r{\APOST /conversations }).last)
    assert_equal "0199-r", sent.fetch("default_runner_executor_public_id")
    assert_equal "@lark", sent.fetch("agent")
    assert_equal "none", sent.fetch("access_default")
    assert_equal "be brief", sent.fetch("instructions")
    assert_equal "m/x", sent.fetch("model")
  end

  # THE PROMPTLESS OPEN: `prompt: nil` sends no
  # `prompt` key at all — the daemon's promptless branch creates the
  # conversation and posts no turn — and the 201 answered carries the
  # conversation and the runner slot alone.
  def test_open_conversation_without_a_prompt_sends_no_prompt_and_answers_the_conversation_alone
    seen = []
    document = { "conversation" => { "public_id" => "c-9" }, "runner" => nil }
    announce(endpoint: recording_endpoint(seen, 201, document))

    answer = core.open_conversation(model: "m/x", directory: "/srv/app")

    assert_equal document, answer
    sent = body_of(seen.grep(%r{\APOST /conversations }).last)
    assert_equal({ "working_directory" => "/srv/app", "environment" => { "root" => "/srv/app", "directories" => [] },
                   "model" => "m/x" }, sent)
    refute sent.key?("prompt"), "no prompt: the key is absent, never an empty string"
    refute answer.key?("turn")
    refute answer.key?("run_public_id")
  end

  # A turn the daemon could not see materialize within its bound is a
  # `pending` document, never a failure.
  def test_a_pending_turn_is_the_document
    announce(endpoint: recording_endpoint([], 201, { "conversation" => { "public_id" => "c-9" }, "pending" => true }))

    answer = core.open_conversation(prompt: "fix it")

    assert answer.fetch("pending")
    assert_equal "c-9", answer.dig("conversation", "public_id")
  end

  # A refusal is the daemon's sentence, whole: the kernel's reason word
  # for a blocked input, the malformed-body sentence for a missing model.
  def test_a_refused_open_raises_the_daemons_sentence
    message = "the kernel blocked the input (unknown_model); the conversation c-9 stands with the input parked " \
      "— edit or delete it through the API, or open a new turn"
    announce(endpoint: recording_endpoint([], 422,
      { "error" => { "code" => "input_blocked", "message" => message, "conversation" => { "public_id" => "c-9" } } }))
    error = assert_raises(Rho::Error) { core.open_conversation(prompt: "fix it", model: "dev/no-such-model") }
    assert_equal message, error.message

    announce(endpoint: recording_endpoint([], 400,
      { "error" => { "code" => "malformed_body", "message" => "model is required, as provider/reference" } }))
    error = assert_raises(Rho::Error) { core.open_conversation(prompt: "fix it") }
    assert_equal "model is required, as provider/reference", error.message

    announce(endpoint: recording_endpoint([], 500, {}))
    error = assert_raises(Rho::Error) { core.open_conversation(prompt: "fix it") }
    assert_equal "the daemon refused to open the conversation", error.message, "an envelope-less refusal has a fallback"
  end

  # `--attach PATH`: the core holds no member plane, so it
  # posts the PATH as this shell resolves it; a path that is not a file is
  # refused in one sentence before any call.
  def test_open_conversation_posts_attachment_paths_and_refuses_a_missing_file_before_any_call
    seen = []
    announce(endpoint: recording_endpoint(seen, 201, IDS))

    Tempfile.create(["shot", ".png"]) do |file|
      core.open_conversation(prompt: "what is this?", attachments: [file.path])
      assert_equal [File.expand_path(file.path)], body_of(seen.grep(%r{\APOST /conversations }).last).fetch("attachments")
    end
    core.open_conversation(prompt: "plain")
    refute body_of(seen.grep(%r{\APOST /conversations }).last).key?("attachments")

    seen.clear
    error = assert_raises(Rho::Error) { core.open_conversation(prompt: "look", attachments: ["/nowhere/diagram.png"]) }
    assert_equal "no such file to attach: /nowhere/diagram.png", error.message
    assert_empty seen.grep(%r{/conversations}), "nothing reached the daemon"
  end

  # ONE HOST-TYPED VERB: the daemon's `/say`, keyed by the
  # followed host's id, carrying the mode, the addressee, the pictures and
  # the kernel's two schedule fields as typed; the 200 document answered.
  def test_say_posts_the_host_route_with_its_mode_addressee_pictures_and_schedule
    seen = []
    document = { "input" => { "public_id" => "in-1", "state" => "steering" },
                 "addressed_to" => { "public_id" => "peer-1", "handle" => "lark" } }
    announce(endpoint: recording_endpoint(seen, 200, document))

    assert_equal document, core.say("al-9", "look at the tests")
    sent = body_of(seen.grep(%r{\APOST /say }).last)
    assert_equal({ "public_id" => "al-9", "text" => "look at the tests", "delivery_mode" => "steer" }, sent, "steer is the default")

    core.say("c-9", "and you?", mode: "queue", to: "@lark", deliver_in: "20m")
    sent = body_of(seen.grep(%r{\APOST /say }).last)
    assert_equal "queue", sent.fetch("delivery_mode")
    assert_equal "@lark", sent.fetch("to"), "the address as typed; the daemon resolves it"
    assert_equal "20m", sent.fetch("deliver_in"), "the delay as typed: the kernel parses it"
    refute sent.key?("deliver_at")

    core.say("c-9", "later", mode: "queue", deliver_at: "2026-09-16T09:00:00+08:00")
    assert_equal "2026-09-16T09:00:00+08:00", body_of(seen.last).fetch("deliver_at"), "an offset passes through as given"
    core.say("c-9", "later", mode: "queue", deliver_at: "2026-09-16T09:00:00")
    assert_equal Time.iso8601("2026-09-16T09:00:00").utc.iso8601, body_of(seen.last).fetch("deliver_at"),
      "a naive time is this terminal's zone, sent in UTC"

    Tempfile.create(["diagram", ".png"]) do |file|
      core.say("c-9", "what is this?", mode: "queue", attachments: [file.path])
      assert_equal [File.expand_path(file.path)], body_of(seen.last).fetch("attachments")
    end
  end

  # Explicit turn fields ride the body as themselves when
  # named and are absent otherwise — the daemon reads them ahead of its
  # own resolution — and the 200 document comes back whole, the turn and
  # the run the daemon's await answered on it.
  def test_say_preserves_explicit_turn_configuration_and_omits_unnamed_fields
    seen = []
    document = { "input" => { "public_id" => "in-2", "state" => "pending" },
                 "turn" => { "public_id" => "t-2" }, "run" => { "public_id" => "al-2" } }
    announce(endpoint: recording_endpoint(seen, 200, document))

    assert_equal document, core.say("c-9", "next", mode: "queue", model: "m/y", approval_mode: "ask", tool_names: ["read"])
    sent = body_of(seen.grep(%r{\APOST /say }).last)
    assert_equal({ "public_id" => "c-9", "text" => "next", "delivery_mode" => "queue", "model" => "m/y",
                   "approval_mode" => "ask", "tool_names" => ["read"] }, sent)

    core.say("c-9", "context alone", mode: "queue", tool_names: [])
    assert_equal [], body_of(seen.grep(%r{\APOST /say }).last).fetch("tool_names")

    core.say("c-9", "plain")
    sent = body_of(seen.grep(%r{\APOST /say }).last)
    refute sent.key?("model"), "no model named: the daemon resolves one"
    refute sent.key?("approval_mode"), "no mode named: the profile's word"
    refute sent.key?("tool_names"), "no subset named: the daemon resolves the default"
  end

  # A steer binds NOW to the reply in flight — a picture or a timed word has
  # nothing to bind to; both flags name two times; an unreadable `--at` is
  # nobody's word. Each is refused here, with the kernel's own word, before
  # any call; a daemon's refusal is its sentence.
  def test_say_refuses_before_any_call_with_the_kernels_word_and_relays_the_daemons_refusal
    seen = []
    announce(endpoint: recording_endpoint(seen, 200, "input" => { "public_id" => "in-4", "state" => "pending" }))

    Tempfile.create(["diagram", ".png"]) do |file|
      error = assert_raises(Rho::Error) { core.say("c-9", "look", attachments: [file.path]) }
      assert_match(/\Aattachments_not_steerable: .*--mode queue/, error.message, "the kernel's word, at rho's edge")
    end
    error = assert_raises(Rho::Error) { core.say("c-9", "x", deliver_in: "20m") }
    assert_match(/\Adeliver_at_not_steerable: /, error.message)
    error = assert_raises(Rho::Error) { core.say("c-9", "x", mode: "queue", deliver_in: "20m", deliver_at: "2026-09-16T09:00:00Z") }
    assert_match(/\Adeliver_at_ambiguous: /, error.message)
    error = assert_raises(Rho::Error) { core.say("c-9", "x", mode: "queue", deliver_at: "tomorrow") }
    assert_match(/\Adeliver_at_invalid: /, error.message)
    error = assert_raises(Rho::Error) { core.say("c-9", "look", mode: "queue", attachments: ["/nowhere/diagram.png"]) }
    assert_equal "no such file to attach: /nowhere/diagram.png", error.message
    assert_empty seen.grep(%r{/say}), "nothing reached the daemon"

    announce(endpoint: recording_endpoint([], 404, "error" => { "code" => "not_followed", "message" => "c-9 is not followed here" }))
    error = assert_raises(Rho::Error) { core.say("c-9", "x") }
    assert_equal "c-9 is not followed here", error.message
  end

  # ---- the door ----

  # Liveness is proven by connecting: no announcement, a dead socket, a
  # health document without a version or an old announcement each fail
  # closed; a proven daemon is kept for the verb's later calls.
  def test_running_daemon_proves_liveness_and_fails_closed
    assert_nil core.running_daemon, "a fresh home announces nothing"

    announce(endpoint: scripted_endpoint(health: { "status" => "ok" }, start: pending_start))
    error = assert_raises(Rho::ConnectionError) { core.running_daemon }
    assert_match(/valid health document/, error.message)

    announce(endpoint: scripted_endpoint(start: pending_start), version: Rho::Daemon::ANNOUNCEMENT_VERSION - 1)
    error = assert_raises(Rho::ConnectionError) { core.running_daemon }
    assert_match(/valid health document/, error.message)

    error = assert_raises(Rho::Error) { Rho::Core.new(home: Rho::Home.resolve(base_url: "https://nexus.example", root: Dir.mktmpdir)).require_daemon }
    assert_equal "no local daemon is running; start one with `rho server`", error.message
  end

  # The budget is stated by the caller because the latency is the caller's
  # to know: /healthz and /status are answered from the daemon's memory,
  # /asks and /device/start make kernel round trips inside the handler.
  # ONE proof per core: the second primitive reuses the daemon the first
  # proved, and grants its own budget alone.
  def test_the_daemon_is_proven_once_per_core_and_each_route_states_its_budget
    boot

    client = core
    granted = capture_read_timeouts do
      client.status_document(client.require_daemon)
      # A fixture daemon without an executor plane refuses the inbox read;
      # the budget it was granted is the fact here, not the answer.
      begin
        client.asks
      rescue Rho::Error
        nil
      end
    end
    assert_equal [Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::KERNEL_ROUND_TRIP.read],
      granted, "/healthz once, /status local, /asks through the kernel"

    granted = capture_read_timeouts { core.start_ceremony(core.require_daemon) }
    assert_equal [Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::DEVICE_START.read], granted
    assert_equal(
      (3 * CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT) +
        (2 * CybrosAgent::Api::BaseClient::DEFAULT_REQUEST_TIMEOUT) +
        Rho::Daemon::Ceremony::ACTIONABLE_WAIT +
        Rho::Core::LOCAL_RESPONSE_SLACK,
      Rho::Core::Budget::DEVICE_START.read,
      "start covers verify, a near-expiry retry, both authority reads, authorization, and response slack"
    )
    assert_equal(CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT + Rho::Core::LOCAL_RESPONSE_SLACK,
      Rho::Core::Budget::DEVICE_CANCEL.read, "cancel has one independent DeviceFlow round trip")
    assert_equal 30 + 60 + Rho::Core::Budget::KERNEL_ROUND_TRIP.read, Rho::Core::Budget.for_tool_call(30_000).read,
      "a call_tool waits the step's clock, the sweep's minute and the kernel round trips"

    endpoint = serve { |client, _request| answer(client, 200, { "canceled" => true }) }
    granted = capture_read_timeouts do
      core.post({ "endpoint" => endpoint, "bearer" => "x" }, "/device/cancel", budget: Rho::Core::Budget::DEVICE_CANCEL)
    end
    assert_equal [Rho::Core::Budget::DEVICE_CANCEL.read], granted
  end

  # THE FAILURE CONTRACT: a daemon that died after the probe, one answering
  # a page where JSON is expected, and one that restarted (a new bearer:
  # 401 on every read) are each one sentence, never a backtrace.
  def test_a_daemon_that_misbehaves_after_the_probe_is_one_sentence
    announce(endpoint: inference_request_endpoint)
    client = core
    error = assert_raises(Rho::ConnectionError) { client.status_document(client.require_daemon) }
    assert_match(/local daemon/, error.message)
    assert_equal 1, error.message.lines.length

    announce(endpoint: page_serving_endpoint)
    client = core
    error = assert_raises(Rho::ConnectionError) { client.status_document(client.require_daemon) }
    assert_match(/not JSON/, error.message)

    announce(endpoint: refusing_endpoint)
    client = core
    error = assert_raises(Rho::ConnectionError) { client.status_document(client.require_daemon) }
    assert_match(/stopped answering \(HTTP 401\)/, error.message)
  end

  # ONE POST per `start_ceremony`: the bootstrapping envelope comes back as
  # it came — the wait is the terminal's (`Rho::Cli::Connect`) — and the
  # next call gets the next answer.
  def test_start_ceremony_is_one_post_answering_the_document_as_it_came
    announce(endpoint: scripted_endpoint(start: nil, starts: [
      [503, { "error" => { "code" => "connection_bootstrapping", "message" => "still being checked" } }],
      [200, { "phase" => "active", "identity" => { "user_public_id" => "0199-user" } }],
    ]))
    client = core
    daemon = client.require_daemon

    first = client.start_ceremony(daemon)
    assert_equal "connection_bootstrapping", first.dig("error", "code"), "not retried here"
    assert_equal "active", client.start_ceremony(daemon).fetch("phase")
  end

  # ---- the ceremony halves that need a real daemon ----

  def test_disconnect_revokes_through_the_daemon_and_in_process_from_the_vault
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(oauth: oauth)
    cli.connect

    document = core.disconnect
    assert_equal %w[runner agent], document["revoked"]
    assert_equal [NexusDoubles::RUNNER_REFRESH_TOKEN, "rt-cybros-api-v1-a.b"], oauth.revocations
    assert_nil core.stored_connection, "the pointer is gone"
    assert_equal :disconnected, daemon.phase

    daemon.stop
    error = assert_raises(Rho::Error) { core.disconnect }
    assert_equal "this home is not connected", error.message, "no daemon and no pointer: the in-process half's word"
  end

  # THE STORED FACTS, with no daemon: the pointer as the disk holds it, its
  # verification, and the default row from the files alone.
  def test_stored_connection_identity_and_facts_answer_from_the_disk
    assert_nil core.stored_connection
    assert_equal "default", core.stored_facts.fetch(:row), "the gem's default row, from the files"

    home.prepare
    Rho::StateFile.new(home.connection_pointer_path).write(
      "version" => Rho::Identity::SESSION_VERSION - 1, "branch" => "runner", "executor_public_id" => "0199-old-runner"
    )
    pointer = core.stored_connection
    assert_equal "0199-old-runner", pointer.fetch("executor_public_id"), "read as it stands"
    assert_raises(Rho::Error, CybrosAgent::Error) { core.stored_identity(pointer) }

    File.write(home.settings_path, JSON.generate("mode" => "runner"))
    assert_nil core.stored_facts, "a runner-mode home declares no row"
  end

  # `adaptation_choice` resolves the row from the files alone — the gem's
  # rows, the home's local rows, the settings' knob — with the resolver
  # beside it, so a surface can print the boot row when the two differ.
  def test_adaptation_choice_resolves_the_row_from_the_files
    RhoTest::LocalRows.write(home.adaptations_path, "mock", models: ["mock-text"])
    RhoTest::LocalRows.write(home.adaptations_path, "other", models: ["other-text"])
    File.write(home.settings_path, JSON.generate("default_model" => "dev/mock-text"))

    resolution = core.adaptation_choice
    assert_equal "dev/mock-text", resolution.subject
    assert_equal "mock", resolution.choice.id
    refute resolution.resolver.boot_differs?("dev/mock-text")

    other = core.adaptation_choice(model: "dev/other-text")
    assert_equal "other", other.choice.id
    assert other.resolver.boot_differs?("dev/other-text")
    assert_equal "mock", other.resolver.boot.id

    # A model without its lane segment is refused the way a missing one is,
    # never the SDK's ArgumentError: the flag's, and the settings' own.
    error = assert_raises(Rho::Error) { core.adaptation_choice(model: "other-text") }
    assert_equal "model is required, as provider/reference", error.message
    File.write(home.settings_path, JSON.generate("default_model" => "mock-text"))
    error = assert_raises(Rho::Error) { core.adaptation_choice }
    assert_equal "model is required, as provider/reference", error.message
  end

  # THE KERNEL'S FACTS for a model, through the daemon: the document, or
  # the daemon's sentence.
  def test_model_facts_and_providers_answer_the_kernels_documents
    announce(endpoint: routed_endpoint(
      "GET /adaptations?model=dev%2Fmock-text" => [[200, { "facts" => { "known" => true, "tool_calls" => true } }]],
      "GET /adaptations?model=dev%2Fgone" => [[503, { "error" => { "code" => "kernel_unavailable", "message" => "no member plane" } }]],
      "GET /providers" => [[200, { "providers" => [{ "id" => "openrouter" }] }]]
    ))

    assert_equal({ "known" => true, "tool_calls" => true }, core.model_facts("dev/mock-text"))
    error = assert_raises(Rho::Error) { core.model_facts("dev/gone") }
    assert_equal "no member plane", error.message
    assert_equal [{ "id" => "openrouter" }], core.providers
  end

  # ---- the run primitives ----

  # A RUN ID NAMES ITS HOST'S ROW: the conversation whose turn it backs —
  # or backed — is what the daemon follows; a host it does not follow is
  # the ordinary state after a restart, said in one sentence.
  def test_run_row_finds_the_row_by_host_or_backing_run_and_names_an_unfollowed_one
    row = { "public_id" => "c-1", "run_public_id" => "al-8", "run_public_ids" => %w[al-7 al-8], "status" => "completed", "complete" => true }
    announce(endpoint: routed_endpoint("GET /followers" => [[200, { "followers" => [row] }]]))

    assert_equal row, core.follower_row("c-1")
    assert_equal row, core.follower_row("al-7")
    error = assert_raises(Rho::Error) { core.follower_row("al-9") }
    assert_equal "this daemon is not following al-9", error.message
  end

  # The listing: this daemon's followers locally, the workspace's through
  # the kernel (its budget, its filters), the side rows on request.
  def test_runs_asks_the_daemon_locally_and_the_workspace_through_the_kernel
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, "GET /followers" => [[200, { "followers" => [{ "public_id" => "al-1" }] }]]))

    granted = capture_read_timeouts do
      assert_equal [{ "public_id" => "al-1" }], core.followers
      core.runs(status: %w[running paused], attention: "any")
      core.followers(side: true)
    end
    lines = seen.grep(%r{\AGET /(?:runs|followers)}).map { |request| request.lines.first.split[1] }
    assert_equal ["/followers", "/runs?status=running%2Cpaused&attention=any", "/followers?side=1"], lines
    assert_equal [Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::LOCAL.read,
                  Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::KERNEL_ROUND_TRIP.read,
                  Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::LOCAL.read], granted,
      "each proof local, then the listing: the workspace's states the kernel budget, the local ones do not"
  end

  # ONE SUBSCRIPTION: the frames in order as `(type, payload)`, a comment
  # line skipped, a frame without an event name dropped, the stream's own
  # end delivered as `closed`; a refusal is the daemon's sentence.
  def test_run_events_yields_the_frames_in_order
    stream = "event: snapshot\ndata: {\"public_id\":\"al-9\",\"text\":\"hel\"}\n\n" \
             ": keep-alive\n\n" \
             "data: {\"orphan\":true}\n\n" \
             "event: text_delta\ndata: {\"text\":\"lo\"}\n\n" \
             "event: turn_status\ndata: {\"status\":\"completed\"}\n\n" \
             "event: closed\ndata: {\"reason\":\"turn_settled\"}\n\n"
    announce(endpoint: routed_endpoint(
      "GET /followers/follow?public_id=al-9" => [[200, stream]],
      "GET /followers/follow?public_id=al-0" => [[404, { "error" => { "code" => "not_followed", "message" => "al-0 is not followed" } }]]
    ))

    frames = []
    core.follower_events("al-9") { |type, payload| frames << [type, payload] }
    assert_equal [["snapshot", { "public_id" => "al-9", "text" => "hel" }], ["text_delta", { "text" => "lo" }],
                  ["turn_status", { "status" => "completed" }], ["closed", { "reason" => "turn_settled" }]], frames

    error = assert_raises(Rho::Error) { core.follower_events("al-0") { |*| nil } }
    assert_equal "al-0 is not followed", error.message
  end

  # THE DEADLINE IS THE SOCKET'S: a stream that sends
  # nothing — the daemon's heartbeat is twenty seconds apart — cannot
  # outlive `deadline`; the read times out and `Deadline` names it,
  # within the budget and a socket's slack, never the heartbeat's.
  def test_run_events_raises_deadline_when_the_socket_stays_silent
    announce(endpoint: serve do |client, request|
      if request.start_with?("GET /healthz")
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION, "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      else
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        client.write("event: snapshot\ndata: {\"public_id\":\"al-9\"}\n\n")
        sleep 4
      end
    end)

    frames = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Rho::Core::Deadline) { core.follower_events("al-9", deadline: 1) { |type, _| frames << type } }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 3, "a 1 s deadline returns in well under the heartbeat"
    assert_equal ["snapshot"], frames, "what arrived before the deadline was delivered"
    assert_match(/timed out following al-9 after 1 s/, error.message)
    assert_kind_of Rho::Error, error
  end

  # EVERY RUN VERB IS ONE ROUTE: the body as the daemon reads it, the
  # document as it answered — a table, one row per primitive.
  def test_the_run_verbs_post_their_bodies_and_answer_their_documents
    seen = []
    task = { "key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed" }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /runs/result?public_id=al-9" => [[200, { "result" => { "status" => "completed", "output" => "done" } }]],
      "GET /runs/task?public_id=al-9&task_key=r1t0" => [[200, { "task" => task }]],
      "GET /runs/transcript?public_id=al-9&limit=5&prefix=r1t0" => [[200, { "transcript" => { "rounds" => [] } }]],
      "GET /runs/graph?public_id=al-9" => [[200, { "graph" => { "mermaid" => "graph TD" } }]],
      "GET /runs/request?public_id=al-9&task_key=r1" => [[200, { "request" => { "entries" => [] } }]],
      "GET /runs/phases?public_id=al-9" => [[200, { "phases" => { "phases" => [] } }]],
      "GET /rules" => [[200, { "grants" => [], "declared" => { "rules" => 1 } }]],
      "GET /asks" => [[200, { "asks" => [{ "kind" => "ask" }] }]],
      "POST /followers/attach" => [[200, { "run" => { "public_id" => "al-9", "status" => "running" } }]],
      "POST /runs/retry" => [[200, { "task" => task }]] * 2,
      "POST /runs/abandon" => [[200, { "task" => task }]],
      "POST /runs/approve" => [[200, { "task" => task, "grant" => { "already" => true } }]],
      "POST /runs/deny" => [[200, { "task" => task.merge("status" => "denied") }]],
      "POST /answer" => [[200, { "answered" => { "task_key" => "r1t0", "door" => "executor" } }]],
      "POST /runs/pause" => [[200, { "run" => { "public_id" => "al-9", "status" => "paused" } }]],
      "POST /runs/resume" => [[200, { "run" => { "public_id" => "al-9", "status" => "running" } }]],
      "POST /followers/subscribe" => [[200, { "follower" => { "public_id" => "al-9", "live" => true } }]],
      "POST /followers/unsubscribe" => [[200, { "follower" => { "public_id" => "al-9", "live" => false } }]],
      "POST /runs/delete" => [[200, { "deleted" => { "public_id" => "al-9" } }]],
      "POST /runs/append" => [[201, { "receipt" => { "accepted_task_keys" => ["p1"] } }]],
      "POST /runs/call_tool" => [[200, { "call_tool" => { "public_id" => "al-r", "task" => task } }]]))

    assert_equal({ "status" => "completed", "output" => "done" }, core.result("al-9"))
    assert_equal task, core.task("al-9", "r1t0")
    assert_equal({ "rounds" => [] }, core.transcript("al-9", limit: 5, prefix: "r1t0"))
    assert_equal({ "mermaid" => "graph TD" }, core.graph("al-9"))
    assert_equal({ "entries" => [] }, core.request_bytes("al-9", "task_key", "r1"))
    assert_equal({ "phases" => [] }, core.phases("al-9"))
    assert_equal({ "rules" => 1 }, core.rules.fetch("declared"))
    assert_equal [{ "kind" => "ask" }], core.asks
    assert_equal "running", core.attach("al-9", live: false).dig("run", "status")
    assert_equal({ "public_id" => "al-9", "live" => false }, body_of(seen.grep(%r{\APOST /followers/attach }).last))
    assert_equal task, core.retry("al-9")
    assert_equal({ "public_id" => "al-9" }, body_of(seen.grep(%r{\APOST /runs/retry }).last), "no key: the daemon reads the trace")
    assert_equal task, core.retry("al-9", "r2", model: "dev/fallback", reasoning_effort: "high", reasoning_enabled: false)
    assert_equal({ "public_id" => "al-9", "task_key" => "r2", "model" => "dev/fallback",
                   "reasoning_effort" => "high", "reasoning_enabled" => false },
      body_of(seen.grep(%r{\APOST /runs/retry }).last), "a named model rides the body as itself")
    assert_equal task, core.abandon("al-9", "r1t0")
    assert_equal({ "public_id" => "al-9", "task_key" => "r1t0" }, body_of(seen.grep(%r{\APOST /runs/abandon }).last))
    assert_equal({ "already" => true }, core.approve("al-9", "r1t0", always: true, match: "git push*").fetch("grant"))
    assert_equal({ "public_id" => "al-9", "task_key" => "r1t0", "always" => true, "match" => "git push*" },
      body_of(seen.grep(%r{\APOST /runs/approve }).last))
    assert_equal "denied", core.deny("al-9", "r1t0", reason: "not now").dig("task", "status")
    assert_equal({ "public_id" => "al-9", "task_key" => "r1t0", "reason" => "not now" }, body_of(seen.grep(%r{\APOST /runs/deny }).last))
    assert_equal "executor", core.answer("al-9", "r1t0", "postgres", outcome: "chosen", token: "tok").fetch("door")
    assert_equal({ "public_id" => "al-9", "task_key" => "r1t0", "content" => "postgres", "outcome" => "chosen", "resolution_token" => "tok" },
      body_of(seen.grep(%r{\APOST /answer }).last))
    assert_equal "paused", core.pause("al-9", force: true).fetch("status")
    assert_equal({ "public_id" => "al-9", "force" => true }, body_of(seen.grep(%r{\APOST /runs/pause }).last))
    assert_equal "running", core.resume("al-9").fetch("status")
    assert core.subscribe("al-9").dig("follower", "live")
    refute core.unsubscribe("al-9").dig("follower", "live")
    assert_equal "al-9", core.delete_run("al-9").dig("deleted", "public_id")
    assert_equal ["p1"], core.append("al-9", steps: [{ "key" => "p1" }]).fetch("accepted_task_keys")
    assert_equal({ "public_id" => "al-9", "steps" => [{ "key" => "p1" }] }, body_of(seen.grep(%r{\APOST /runs/append }).last))
    assert_equal "al-r", core.call_tool("0199-r", "ps", { "all" => true }, timeout_ms: 5_000).fetch("public_id")
    assert_equal({ "runner_executor_public_id" => "0199-r", "tool" => "ps", "input" => { "all" => true }, "timeout_ms" => 5_000 },
      body_of(seen.grep(%r{\APOST /runs/call_tool }).last))
  end

  # THE CONVERSATION ARM OF `attach`: `host_type:
  # "conversation"` rides the body as itself — the daemon follows the
  # conversation's own feed and fetches no run — and is absent on the
  # run arm, which is unchanged; the document comes back whole.
  def test_attach_posts_the_host_type_when_named_and_answers_the_conversation_document
    seen = []
    document = { "conversation" => { "public_id" => "c-9" }, "run" => { "public_id" => "c-9", "host_type" => "conversation" } }
    announce(endpoint: recording_endpoint(seen, 200, document))

    assert_equal document, core.attach("c-9", host_type: "conversation")
    assert_equal({ "public_id" => "c-9", "live" => true, "host_type" => "conversation" },
      body_of(seen.grep(%r{\APOST /followers/attach }).last))
    core.attach("al-9")
    refute body_of(seen.grep(%r{\APOST /followers/attach }).last).key?("host_type"), "the run arm names no type"
  end

  # THE REPLAY'S MAINLINE: `turns` is one `GET
  # /conversations/turns` — the position window and the cap ride the
  # query as typed, absent when unnamed — answering the daemon's turns
  # document whole (the rows and the page's own bounds); the daemon's
  # refusal is its sentence.
  def test_turns_reads_the_conversations_turns_document_over_one_route
    seen = []
    document = { "turns" => [{ "public_id" => "t-1", "position" => 0, "kind" => "direct_reply", "role" => "user" }],
                 "pagination" => { "after_position" => 0, "has_more" => false } }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/turns?public_id=c-9" => [[200, document]],
      "GET /conversations/turns?public_id=c-9&after_position=3&limit=50" => [[200, document]],
      "GET /conversations/turns?public_id=c-nope" => [[404, { "error" => { "code" => "not_found", "message" => "no such conversation" } }]]))

    assert_equal document, core.turns("c-9")
    assert_equal document, core.turns("c-9", after_position: 3, limit: 50)
    assert_equal 2, seen.grep(%r{\AGET /conversations/turns\?public_id=c-9}).length
    error = assert_raises(Rho::Error) { core.turns("c-nope") }
    assert_equal "no such conversation", error.message
  end

  # WHERE THE TOOLS ARE POINTED, as two primitives: `environment` reads the document, `repoint_
  # environment` moves the root — nil clears back to the settings — under
  # the environment budget (a rebuild waits on stopped handlers), each
  # answering the `environment` document, a refusal as the daemon's sentence.
  def test_environment_reads_and_repoint_environment_moves_the_tools_over_the_two_routes
    seen = []
    document = { "environment" => { "root" => "/srv/app", "source" => "api" } }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /environment" => [[200, { "environment" => { "root" => "/srv/app", "source" => "settings" } }]],
      "POST /environment" => [[200, document], [200, { "environment" => { "source" => "unset" } }], [200, document],
                              [422, { "error" => { "code" => "not_a_directory", "message" => "/nope is not a directory" } }]]))

    assert_equal({ "root" => "/srv/app", "source" => "settings" }, core.environment)
    assert_equal({ "root" => "/srv/app", "source" => "api" }, core.repoint_environment("/srv/app"))
    assert_equal({ "root" => "/srv/app" }, body_of(seen.grep(%r{\APOST /environment }).last))
    assert_equal({ "source" => "unset" }, core.repoint_environment(nil))
    assert_equal({ "root" => nil }, body_of(seen.grep(%r{\APOST /environment }).last), "nil is the typed clear")
    granted = capture_read_timeouts { core.repoint_environment("/srv/app") }
    assert_equal [Rho::Core::Budget::LOCAL.read, Rho::Core::Budget::ENVIRONMENT.read], granted,
      "/healthz once, then the move under the environment budget (the rebuild waits on stopped handlers)"
    error = assert_raises(Rho::Error) { core.repoint_environment("/nope") }
    assert_equal "/nope is not a directory", error.message
  end

  # THE CONVERSATION'S ENVIRONMENT, as three primitives: the record read (`GET /conversations/environment`, the
  # id on the query as rho's GET doors carry ids), the bind under
  # ABSENT-means-keep — a field not named is not sent, nil and `[]` are
  # sent as themselves — and the live table; each answering its
  # document, a refusal as the daemon's sentence.
  def test_the_environment_primitives_read_bind_and_list_over_their_routes
    seen = []
    document = { "environment" => { "root" => "/srv/app", "directories" => [], "anchor" => "c-1", "source" => "conversation",
                                    "lock_version" => 0, "resolved" => true, "relayed" => nil } }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/environment" => [[200, document],
                                           [404, { "error" => { "code" => "host_not_followed", "message" => "not following c-9" } }]],
      "POST /conversations/environment" => [[200, document], [200, document], [200, document],
                                            [422, { "error" => { "code" => "protected_root", "message" => "/rho is protected" } }]],
      "GET /environments" => [[200, { "environments" => [{ "conversation" => "c-1", "root" => "/srv/app" }] }]]))

    assert_equal document.fetch("environment"), core.conversation_environment("c-1")
    assert_match(%r{\AGET /conversations/environment\?public_id=c-1 }, seen.grep(%r{\AGET /conversations/environment}).first)
    assert_equal "not following c-9", assert_raises(Rho::Error) { core.conversation_environment("c-9") }.message

    assert_equal document.fetch("environment"), core.bind_environment("c-1", root: "/srv/app")
    assert_equal({ "public_id" => "c-1", "root" => "/srv/app" }, body_of(seen.grep(%r{\APOST /conversations/environment}).last),
      "directories not named: not sent (keep)")
    core.bind_environment("c-1", directories: ["/srv/docs"])
    assert_equal({ "public_id" => "c-1", "directories" => ["/srv/docs"] }, body_of(seen.grep(%r{\APOST /conversations/environment}).last),
      "root not named: not sent (keep)")
    core.bind_environment("c-1", root: nil, directories: [])
    assert_equal({ "public_id" => "c-1", "root" => nil, "directories" => [] }, body_of(seen.grep(%r{\APOST /conversations/environment}).last),
      "nil and [] are the typed clears")
    assert_equal "/rho is protected", assert_raises(Rho::Error) { core.bind_environment("c-1", root: "/rho") }.message

    assert_equal [{ "conversation" => "c-1", "root" => "/srv/app" }], core.environments
  end

  # `open_conversation(directory:, directories:)` BINDS: a named directory rides as `working_directory`
  # AND as the `environment` the daemon validates and writes; with none
  # named, `Dir.pwd` stays descriptive and no environment is sent.
  def test_open_conversation_with_a_directory_sends_the_environment_beside_the_working_directory
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations" => [[201, { "conversation" => { "public_id" => "c-1" } }]]))

    core.open_conversation(prompt: "fix it", directory: "/srv/app", directories: ["/srv/docs"])
    body = body_of(seen.grep(%r{\APOST /conversations }).last)
    assert_equal "/srv/app", body.fetch("working_directory")
    assert_equal({ "root" => "/srv/app", "directories" => ["/srv/docs"] }, body.fetch("environment"))

    core.open_conversation(prompt: "fix it")
    body = body_of(seen.grep(%r{\APOST /conversations }).last)
    assert_equal Dir.pwd, body.fetch("working_directory")
    refute body.key?("environment"), "nothing named: nothing bound"
  end

  # A refusal is the daemon's sentence; an inbox that is not one (a page,
  # a document without `asks`) raises too — the surfaces decide whether
  # that is silence (`rho status`) or a failure.
  def test_a_run_verb_refusal_is_the_daemons_sentence
    announce(endpoint: routed_endpoint(
      "POST /runs/retry" => [[409, { "error" => { "code" => "not_failed", "message" => "r1 is not failed" } }]],
      "GET /runs/task" => [[404, { "error" => { "code" => "not_found", "message" => "no task r9" } }]],
      "GET /asks" => [[503, { "error" => { "code" => "executor_plane_unavailable", "message" => "none" } }],
                      [200, { "state" => "active" }]]
    ))

    assert_equal "r1 is not failed", assert_raises(Rho::Error) { core.retry("al-9") }.message
    assert_equal "no task r9", assert_raises(Rho::Error) { core.task("al-9", "r9") }.message
    assert_equal "none", assert_raises(Rho::Error) { core.asks }.message
    assert_equal "the daemon answered no inbox", assert_raises(Rho::Error) { core.asks }.message

    announce(endpoint: page_serving_endpoint)
    assert_raises(Rho::ConnectionError) { core.asks }
  end

  # THE REFUSAL, TYPED: a daemon
  # envelope reaches a surface as `Core::Refused` — the sentence as the
  # message, unchanged, AND the code word and the HTTP status as readers,
  # so a surface tells a 409 `runner_elsewhere` by its code and never by
  # its sentence; an envelope-less refusal is the fallback sentence, no
  # code, its status.
  def test_a_daemon_refusal_carries_its_code_and_status_beside_the_sentence
    sentence = "c-1 runs on exr_9: a port is this daemon's loopback endpoint"
    announce(endpoint: routed_endpoint(
      "POST /conversations/environment" => [[409, { "error" => { "code" => "runner_elsewhere", "message" => sentence } }]],
      "GET /runs/task" => [[500, {}]]
    ))

    error = assert_raises(Rho::Core::Refused) { core.bind_environment("c-1", fs: { "url" => "http://127.0.0.1:1" }) }
    assert_kind_of Rho::Error, error
    assert_equal ["runner_elsewhere", 409, sentence], [error.code, error.status, error.message]

    error = assert_raises(Rho::Core::Refused) { core.task("al-9", "r9") }
    assert_equal [nil, 500, "the daemon refused to read the task"], [error.code, error.status, error.message]
  end

  # ---- the record primitives ----

  def test_the_record_verbs_post_their_bodies_and_answer_their_documents
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /inputs?public_id=c-1" => [[200, { "inputs" => [{ "public_id" => "cin-1" }] }]],
      "POST /inputs/delete" => [[200, { "deleted" => { "public_id" => "cin-1" } }]],
      "POST /inputs/update" => [[200, { "input" => { "public_id" => "cin-2", "state" => "pending" } }]],
      "PUT /conversations/access" => [[200, { "access" => { "default" => "full", "entries" => [] } }]],
      "POST /conversations/prompt_preview" => [[200, { "preview" => { "mechanism" => "assembly" } }]],
      "GET /prompt/documents?slot=system_prompt" => [[200, { "prompt_document" => { "content" => "hi" } }]],
      "GET /prompt/documents" => [[200, { "prompt_documents" => [] }]],
      "POST /conversations/rewind" => [[200, { "rewind" => { "conversation" => "c-2", "world" => { "status" => "kept" } } }]],
      "POST /conversations/regenerate" => [[200, { "regenerate" => { "turn" => "t-1", "world" => { "status" => "kept" } } }]],
      "GET /conversations/variants?public_id=c-1&turn=t-1" => [[200, { "variants" => [{ "public_id" => "v-1" }] }]],
      "POST /conversations/variant" => [[200, { "variant" => { "public_id" => "v-1" } }]],
      "GET /skills/show?scope=user&name=review" => [[200, { "memory" => { "content" => "# review" } }]],
      "GET /skills" => [[200, { "skills" => { "user" => [], "workspace" => [] } }]],
      "POST /skills/push" => [[201, { "memory" => { "path" => "user/skills/review", "bytesize" => 8 } }]],
      "POST /skills/rm" => [[200, { "deleted" => { "path" => "user/skills/review" } }]],
      "GET /uploads/bytes?public_id=u-1&kind=thumbnail" => [[200, { "png" => true }]]))

    assert_equal [{ "public_id" => "cin-1" }], core.inputs("c-1")
    assert_equal "cin-1", core.delete_input("c-1", "cin-1").dig("deleted", "public_id")
    assert_equal({ "public_id" => "c-1", "input_public_id" => "cin-1" }, body_of(seen.grep(%r{\APOST /inputs/delete }).last))
    assert_equal "cin-2", core.update_input("c-1", "cin-2", text: "again", schedule: { "deliver_in" => "5m" }).fetch("public_id")
    assert_equal({ "public_id" => "c-1", "input_public_id" => "cin-2", "text" => "again", "deliver_in" => "5m" },
      body_of(seen.grep(%r{\APOST /inputs/update }).last))
    core.update_input("c-1", "cin-2", text: "  ")
    refute body_of(seen.grep(%r{\APOST /inputs/update }).last).key?("text"), "a blank text is no text"
    assert_equal "full", core.access("c-1").fetch("default")
    assert_equal({ "public_id" => "c-1" }, body_of(seen.grep(%r{\APUT /conversations/access }).last))
    core.replace_access("c-1", { "op" => "add", "principal" => "@lark", "level" => "read" })
    assert_equal({ "public_id" => "c-1", "change" => { "op" => "add", "principal" => "@lark", "level" => "read" } },
      body_of(seen.grep(%r{\APUT /conversations/access }).last))
    assert_equal "assembly", core.prompt_preview("c-1", model: "m/x", prompt: "and?", to: "@n", variables: { "a" => "1" },
      template: { "blocks" => [] }).fetch("mechanism")
    assert_equal({ "public_id" => "c-1", "model" => "m/x", "prompt" => "and?", "to" => "@n", "variables" => { "a" => "1" },
                   "template" => { "blocks" => [] } }, body_of(seen.grep(%r{\APOST /conversations/prompt_preview }).last))
    assert_equal "hi", core.prompt_documents(slot: "system_prompt").dig("prompt_document", "content")
    assert_equal [], core.prompt_documents.fetch("prompt_documents")
    assert_equal "c-2", core.rewind("c-1", "t-1", keep_checkpoints: true, title: "again").fetch("conversation")
    assert_equal({ "public_id" => "c-1", "turn" => "t-1", "keep_checkpoints" => true, "title" => "again" },
      body_of(seen.grep(%r{\APOST /conversations/rewind }).last))
    assert_equal "t-1", core.regenerate("c-1", "t-1", idempotency_key: "regenerate-test", model: "m/y").fetch("turn")
    assert_equal({ "public_id" => "c-1", "turn" => "t-1", "idempotency_key" => "regenerate-test", "keep_checkpoints" => false, "model" => "m/y" },
      body_of(seen.grep(%r{\APOST /conversations/regenerate }).last))
    assert_equal [{ "public_id" => "v-1" }], core.variants("c-1", "t-1")
    assert_equal "v-1", core.variant("c-1", "t-1", "v-1", concealed: true).fetch("public_id")
    assert_equal({ "public_id" => "c-1", "turn" => "t-1", "variant" => "v-1", "concealed" => true },
      body_of(seen.grep(%r{\APOST /conversations/variant }).last))
    assert_equal({ "user" => [], "workspace" => [] }, core.skills)
    assert_equal 8, core.push_skill(name: "review", description: "d", content: "# review", scope: "user",
      expected_public_id: nil, expected_lock_version: nil).fetch("bytesize")
    assert_equal({ "scope" => "user", "name" => "review", "description" => "d", "content" => "# review",
                   "expected_public_id" => nil, "expected_lock_version" => nil },
      body_of(seen.grep(%r{\APOST /skills/push }).last))
    assert_equal "# review", core.show_skill("review", scope: "user").fetch("content")
    assert_equal "user/skills/review", core.remove_skill("review", scope: "user",
      expected_public_id: "019a0000-0000-7000-8000-000000000001", expected_lock_version: 4).fetch("path")
    bytes = core.upload_bytes("u-1", kind: "thumbnail")
    assert_equal Encoding::BINARY, bytes.encoding
    assert_equal JSON.generate("png" => true), bytes
  end

  # ---- the wire shapers ----

  def test_schedule_fields_pass_the_kernels_two_fields_through_and_refuse_the_ambiguity
    assert_equal({}, Rho::Core.schedule_fields)
    assert_equal({ "deliver_in" => "20m" }, Rho::Core.schedule_fields(deliver_in: "20m"))
    assert_equal({ "deliver_at" => "2026-09-16T09:00:00Z" }, Rho::Core.schedule_fields(deliver_at: "2026-09-16T09:00:00Z"))
    assert_equal Time.iso8601("2026-09-16T09:00:00").utc.iso8601, Rho::Core.deliver_at_wire("2026-09-16T09:00:00")
    assert_match(/\Adeliver_at_ambiguous: /, assert_raises(Rho::Error) { Rho::Core.schedule_fields(deliver_at: "x", deliver_in: "y") }.message)
    assert_match(/\Adeliver_at_invalid: /, assert_raises(Rho::Error) { Rho::Core.deliver_at_wire("tomorrow") }.message)
  end
end
