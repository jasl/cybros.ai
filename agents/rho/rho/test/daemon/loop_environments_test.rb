require "support/daemon_loop_helpers"

class DaemonLoopsTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  # ---- the turn author reads the binding ----

  # A hook that records what the Draft carried, so the environment a
  # remote runner leaves nil is observable from outside.
  def recording_author(path)
    file = File.join(@root, "author.rb")
    File.write(file, <<~RUBY)
      module RecordingAuthorExtension
        NAME = "rho.recording"
        def self.register(api)
          api.on(:turn_author) do |draft, _ctx|
            File.write(#{path.inspect}, JSON.generate("environment" => draft.environment&.root,
              "tools" => draft.tools.map { |entry| entry.dig("function", "name") }))
            draft
          end
        end
      end
    RUBY
    file
  end

  # This machine's own runner is listed too — as a sweep-only rho reads:
  # `offline` while it works.
  def remote_api(**options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      executors: [NexusDoubles.remote_runner("0199-runner", display_name: "Helper", root: "/home/rho", presence: "offline",
        last_seen_at: "2026-09-08T00:00:00Z", tools: [NexusDoubles.served_tool("bash")]),
        NexusDoubles.remote_runner("0199-h"), NexusDoubles.remote_runner("0199-k", display_name: "Other",
        tools: [NexusDoubles.served_tool("read", description: "an echo of the path"), NexusDoubles.served_tool("slow_read")])],
      **options)
  end

  # A REMOTE RUNNER BOUND AT THE OPEN: the lead is that runner's announced
  # snapshot and nothing else, the Draft's environment is nil (the tools
  # run where the runner is), and the turn's `tool_names` — never nil, even
  # with compose on — is the kernel's ∪ this rho's agent-served ∪ the
  # runner's announced names, so this host is never offered another
  # runner's tools; the profile's union is declared once for it.
  def test_a_remote_runner_renders_its_snapshot_as_the_lead_and_narrows_the_turn
    recorded = File.join(@root, "draft.json")
    api = remote_api
    daemon = member_ready(boot(config: tiered("extension_paths" => [recording_author(recorded)])), api, identity: RUNNER_IDENTITY)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-h" })

    assert_equal "201", code, answer.inspect
    assert_equal({ "executor_public_id" => "0199-h", "display_name" => "Elsewhere", "presence" => "online" },
      answer.fetch("runner"), "the create response's binding, for the three-state slot")
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal [{ "role" => "developer", "position" => "lead", "text" => "Relative paths resolve against /srv/elsewhere." }],
      input.fetch("inline"), "the announced snapshot alone; no per-tool lines, no guideline (the profile's slot)"
    assert_equal %w[manage_scheduled_job read_scheduled_jobs slow_read slow_write todo_write compose task], input.fetch("tool_names"),
      "the runner tools, agent tools, then kernel tools"
    draft = JSON.parse(File.read(recorded))
    assert_nil draft.fetch("environment"), "the tools run where the runner is"
    assert_equal %w[manage_scheduled_job read_scheduled_jobs slow_read slow_write todo_write compose task], draft.fetch("tools"),
      "the seed a hook copies is the turn's surface"
    assert_equal "0199-h", store.find("c-1").runner

    assert_equal 1, api.configuration_declarations.length, "the union, declared for the binding"
    names = api.configuration_declarations.fetch(0).dig("configuration", "tool_definitions").map { |e| e.dig("function", "name") }
    assert_includes names, "slow_read"
    assert_includes names, "bash", "this machine's own entries stay in the union"
    assert_equal ["/agent_api/v1/executors/0199-h"], api.requests.map(&:first).grep(%r{/executors/}), "one discovery read, then the cache"
  end

  # THIS MACHINE'S OWN RUNNER: byte-identical to HEAD — the local lead,
  # the local environment, no `tool_names` with compose on — and the
  # profile is not re-declared for a binding that adds no name.
  def test_the_own_runner_keeps_the_local_bytes
    recorded = File.join(@root, "draft.json")
    api = remote_api
    daemon = member_ready(boot(config: tiered("extension_paths" => [recording_author(recorded)])), api, identity: RUNNER_IDENTITY)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    assert_equal "0199-runner", api.conversation_creates.fetch(0).dig("conversation", "runner_executor_public_id")
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert input.dig("inline", 0, "text").start_with?("Relative paths resolve against #{@root}/work/users/user-1.")
    refute input.key?("tool_names"), "compose on, no remote name in the union: the whole declaration runs"
    assert_equal File.join(@root, "work", "users", "user-1"), JSON.parse(File.read(recorded)).fetch("environment")
    assert_empty api.configuration_declarations, "nothing to add to the union: nothing declared"
    assert_equal "0199-runner", store.find("c-1").runner
    assert_equal({ "executor_public_id" => "0199-runner" }, answer.fetch("runner"),
      "this machine's own runner: the id alone — kernel presence is for a foreign executor, and the slot stays silent")
  end

  # A HANDOFF MADE ELSEWHERE: `runner_bound` on the host feed moves the row's binding, and
  # the NEXT `say` renders the lead for the new runner — inline, the same door the open
  # used — with the narrowed names. THE LEAD RIDES EVERY TURN (the kernel's developer
  # inline is this turn's only, and a say that carried none sent the model no environment
  # and no tool lines): the say after carries the same lead again, byte for byte — a
  # runner change changes its BYTES, never whether it rides. A byte collision the kernel
  # accepted is REPORTED on the follow line and the union keeps this rho's bytes; the
  # union is declared once for the new names, however many turns ride it.
  def test_a_runner_bound_on_the_feed_renders_the_lead_for_the_new_runner_on_every_say
    events = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS + [
      { "public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "runner_bound",
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-06T00:00:01Z",
        "payload" => { "executor_public_id" => "0199-k", "previous_executor_public_id" => "0199-runner", "by" => "0199-steward" } },
    ]
    api = remote_api(conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    daemon = member_ready(boot(config: tiered), api, identity: RUNNER_IDENTITY)
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    wait_for { store.find("c-1")&.runner == "0199-k" }
    wait_for { api.configuration_declarations.length == 1 }

    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=host\.runner_bound host=c-1 executor=0199-k previous=0199-runner by=0199-steward conflict=read/, log)
    names = api.configuration_declarations.fetch(0).dig("configuration", "tool_definitions").map { |e| e.dig("function", "name") }
    assert_equal 1, names.count("read")
    read = api.configuration_declarations.fetch(0).dig("configuration", "tool_definitions").find { |e| e.dig("function", "name") == "read" }
    refute_equal "an echo of the path", read.dig("function", "description"), "this rho's bytes stand"
    assert_includes names, "slow_read"

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "more" })
    assert_equal "200", response.code, response.body
    assert_equal({ "executor_public_id" => "0199-k", "display_name" => "Other", "presence" => "online" },
      JSON.parse(response.body).fetch("runner"), "the binding as this daemon last learned it")
    input = api.conversation_inputs.fetch(1).fetch("input")
    remote_lead = [{ "role" => "developer", "position" => "lead", "text" => "Relative paths resolve against /srv/elsewhere." }]
    assert_equal remote_lead, input.fetch("inline"), "the lead rendered for the new runner"
    assert_equal %w[manage_scheduled_job read read_scheduled_jobs slow_read todo_write compose task], input.fetch("tool_names")
    refute_equal api.conversation_inputs.fetch(0).dig("input", "inline"), remote_lead,
      "the open's lead was this machine's: the runner change changed the bytes"

    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "and then" })
    input = api.conversation_inputs.fetch(2).fetch("input")
    assert_equal remote_lead, input.fetch("inline"), "the same lead rides the say after, byte for byte"
    assert_equal %w[manage_scheduled_job read read_scheduled_jobs slow_read todo_write compose task], input.fetch("tool_names")
    assert_equal 1, api.configuration_declarations.length, "the union moved once"
  end

  # A REAPED BINDING: the `runner_bound` payload names no
  # executor, the row's binding is nil, and the next `say` is local again
  # — the local lead, no narrowing left, and the `none` slot.
  def test_a_reap_on_the_feed_makes_the_next_say_local_again
    events = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS + [
      { "public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "runner_bound",
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-06T00:00:01Z",
        "payload" => { "executor_public_id" => "0199-h", "previous_executor_public_id" => "0199-runner", "by" => "0199-steward" } },
      { "public_id" => "ev-4", "sequence" => 4, "cursor" => "c4", "type" => "runner_bound",
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-06T00:00:02Z",
        "payload" => { "previous_executor_public_id" => "0199-h", "by" => "0199-steward" } },
    ]
    api = remote_api(conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    daemon = member_ready(boot(config: tiered), api, identity: RUNNER_IDENTITY)
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    wait_for { File.read(daemon.home.log_path, encoding: Encoding::UTF_8).scan("event=host.runner_bound").length == 2 }
    assert_nil store.find("c-1").runner

    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "more" })
    assert_equal "200", response.code, response.body
    body = JSON.parse(response.body)
    assert body.key?("runner")
    assert_nil body.fetch("runner"), "none bound: the slot says so"
    input = api.conversation_inputs.fetch(1).fetch("input")
    assert input.dig("inline", 0, "text").start_with?("Relative paths resolve against #{@root}/work/users/user-1."),
      "the local lead again"
    refute input.key?("tool_names"), "no remote name left in the union"
  end

  # A binding whose runner discovery no longer answers (reaped, revoked,
  # out of scope): the turn still opens — NO lead at all (an empty lead
  # sends no inline entry, which the kernel would refuse; the guideline
  # reaches the model through rho's profile slot), the kernel's and this
  # rho's agent names alone — and the fact is logged; the kernel's own
  # refusal, if any, is the caller's to read.
  def test_a_remote_runner_discovery_cannot_show_still_opens_the_turn
    api = remote_api
    daemon = member_ready(boot(config: tiered), api, identity: RUNNER_IDENTITY)

    code, = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-gone" })

    assert_equal "201", code
    input = api.conversation_inputs.fetch(0).fetch("input")
    refute input.key?("inline"), "no fragment, no lead: nothing to send"
    assert_equal %w[manage_scheduled_job read_scheduled_jobs todo_write compose task], input.fetch("tool_names"), "the agent tools remain available"
    assert_match(/event=runner\.not_addressable executor=0199-gone/, File.read(daemon.home.log_path, encoding: Encoding::UTF_8))
  end

  # An unreadable default cannot silently open in a different workspace.
  def test_a_broken_settings_file_refuses_a_new_conversation_without_falling_back
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    File.write(daemon.home.settings_path, "{ not json")

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "422", code
    assert_equal "settings_unreadable", answer.dig("error", "code")
    assert_empty api.conversation_creates
    assert_match(/event=settings\.unreadable/, File.read(daemon.home.log_path, encoding: Encoding::UTF_8))
  end

  # ---- the conversation's environment ----

  def project(name)
    File.join(@root, name).tap { |path| FileUtils.mkdir_p(path) }
  end

  def record_of(api, conversation)
    api.store_entries_of(conversation).find { |row| row["namespace"] == "rho.environment" && row["key"] == "binding" }
  end

  # THE OPEN WITH A ROOT SET: validated BEFORE the create — a root that
  # is no directory, or under a protected root, is refused and nothing
  # is created — then create → the row remembered → the RECORD written
  # (`rho.environment`/`binding`, `{root, directories, anchor}` exactly,
  # the anchor the new conversation) → the first input, whose lead names
  # the bound root (rendered from the validated body, the surface being
  # built before the create). The answer carries the environment.
  def test_do_with_an_environment_validates_before_the_create_writes_the_record_after_it_and_leads_with_the_root
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    src = project("src")
    docs = project("docs")

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text",
                                  "environment" => { "root" => File.join(@root, "nope") } })
    assert_equal ["422", "not_a_directory"], [code, answer.dig("error", "code")]
    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text",
                                  "environment" => { "root" => src, "directories" => [Rho.root] } })
    assert_equal ["422", "protected_root"], [code, answer.dig("error", "code")]
    assert_empty api.conversation_creates, "refused before the create"

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "working_directory" => src,
                                  "environment" => { "root" => src, "directories" => [docs] } })

    assert_equal "201", code, answer.inspect
    assert_equal({ "root" => src, "directories" => [docs], "resolved" => true }, answer.fetch("environment"))
    record = record_of(api, "c-1")
    refute_nil record, "the record is written after the create"
    assert_equal [{ "root" => src, "directories" => [docs], "anchor" => "c-1" }, 0], record.values_at("value", "lock_version")
    paths = api.requests.map(&:first)
    assert_operator paths.index { |path| path.end_with?("/conversations/c-1/store_entries") }, :<,
      paths.index { |path| path.end_with?("/conversations/c-1/inputs") }, "the record before the first input"
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert lead.start_with?("Relative paths resolve against #{src}."), "the lead names the bound root: #{lead.inspect}"

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })
    assert_equal "201", code
    refute answer.key?("environment"), "no root set named: nothing bound, nothing answered"
    assert_nil record_of(api, "c-2"), "a plain open writes no record"
  end

  # THE PROMPTLESS OPEN BINDS TOO (`session/new {cwd}` opens with no turn): the record is written and the first `say` leads with it.
  def test_a_promptless_open_with_a_root_writes_the_record
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    src = project("src")

    code, answer = open(daemon, { "environment" => { "root" => src } })

    assert_equal "201", code, answer.inspect
    assert_equal({ "root" => src, "directories" => [], "resolved" => true }, answer.fetch("environment"))
    assert_equal({ "root" => src, "directories" => [], "anchor" => "c-1" }, record_of(api, "c-1").fetch("value"))
    assert_empty api.conversation_inputs
  end

  # THE READ EDGE, EVERY TURN: `say` reads the record at
  # the lead render — a person's PATCH through the SDK between two says
  # reaches the next lead, with `lock_version` untouched by rho (no
  # write on a read). The say between carries the lead too, naming the
  # root set unchanged (the lead rides every turn; the "rendered once per tuple" memo is gone).
  def test_say_reads_the_record_at_the_lead_and_a_patch_between_two_says_reaches_the_next_lead
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    src = project("src")
    moved = project("moved")
    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "environment" => { "root" => src } })

    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "more" })
    lead = api.conversation_inputs.fetch(1).dig("input", "inline", 0, "text")
    assert lead.start_with?("Relative paths resolve against #{src}."), "the lead rides again, naming the same root set: #{lead.inspect}"

    api.patch_store_entry("c-1", namespace: "rho.environment", key: "binding",
      value: { "root" => moved, "directories" => [], "anchor" => "c-1" })
    response = request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "and then" })

    assert_equal "200", response.code, response.body
    lead = api.conversation_inputs.fetch(2).dig("input", "inline", 0, "text")
    assert lead.start_with?("Relative paths resolve against #{moved}."), "the next lead names the new root: #{lead.inspect}"
    assert_empty api.store_entry_updates, "a read, never a write"
    assert_equal 1, record_of(api, "c-1").fetch("lock_version"), "the person's version stands"
    assert_equal({ "root" => moved, "directories" => [] }, JSON.parse(response.body).fetch("environment").slice("root", "directories"))
  end

  # A ROOT SET ON A RUNNER ELSEWHERE: after the create the record
  # is relayed to that runner — `environment_bind` on its announced park,
  # the conversation id on the input — BEFORE the first input, so the
  # runner claims the bind row ahead of the turn's rows; the lead names
  # the bound root beside the snapshot; the answer says what the runner
  # knows. The next `say` relays nothing on the same tuple and boot.
  def test_do_on_a_remote_runner_relays_the_record_before_the_first_input
    api = remote_api(
      executors: [NexusDoubles.remote_runner("0199-h", booted_at: "2026-09-17T06:00:00Z")],
      task_detail: { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "environment_bind",
                     "output" => "bound", "result" => { "is_error" => false },
                     "structured_content" => { "applied" => true, "resolved" => true, "booted_at" => "2026-09-17T06:00:00Z" },
                     "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-17T00:00:00Z" }
    )
    daemon = member_ready(boot(config: tiered), api, identity: RUNNER_IDENTITY)
    src = project("src")

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-h",
                                  "environment" => { "root" => src } })

    assert_equal "201", code, answer.inspect
    assert_equal({ "root" => src, "directories" => [], "resolved" => true,
                   "relayed" => { "runner" => "0199-h", "state" => "confirmed", "booted_at" => "2026-09-17T06:00:00Z", "resolved" => true } },
      answer.fetch("environment"))
    relayed = api.loop_creates.select { |body| body.dig("agent_loop", "steps", 0, "tool", "name") == "environment_bind" }
    assert_equal 1, relayed.length
    assert_equal({ "root" => src, "directories" => [], "anchor" => "c-1", "conversation_public_id" => "c-1" },
      relayed.fetch(0).dig("agent_loop", "steps", 0, "tool", "input"))
    paths = api.requests.map(&:first)
    assert_operator paths.index { |path| path.end_with?("/agent_loops") }, :<,
      paths.index { |path| path.end_with?("/conversations/c-1/inputs") }, "the relay row before the first input"
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert_includes lead, src, "the lead names the bound root"
    assert_includes lead, "Relative paths resolve against /srv/elsewhere.", "beside the snapshot's fragments"

    request(daemon, :post, "/say", token: bearer(daemon), body: { public_id: "c-1", text: "more" })
    assert_equal 1, api.loop_creates.length, "the same tuple on the same boot: nothing relayed"
  end

  # A ROOT SET THAT IS THE RUNNER'S, NOT THIS HOST'S (the box's plain cell of 2026-09-18: `rho do --dir /app --runner <container>` from a host with no `/app`): the open is judged here for protected
  # roots alone — 201, the record written and relayed, this host's
  # placement `resolved: false`, the runner's answer on `relayed`; a
  # protected root is still refused; the same absent root on this host's
  # OWN runner stays 422 `not_a_directory` (the pin above).
  def test_do_on_a_remote_runner_accepts_a_root_this_host_does_not_have
    api = remote_api(
      executors: [NexusDoubles.remote_runner("0199-h", root: "/app", booted_at: "2026-09-17T06:00:00Z")],
      task_detail: { "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "environment_bind",
                     "output" => "bound", "result" => { "is_error" => false },
                     "structured_content" => { "applied" => true, "resolved" => true, "booted_at" => "2026-09-17T06:00:00Z" },
                     "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-17T00:00:00Z" }
    )
    daemon = member_ready(boot(config: tiered), api, identity: RUNNER_IDENTITY)
    absent = File.join(@root, "app")
    refute File.directory?(absent)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-h",
                                  "environment" => { "root" => absent } })

    assert_equal "201", code, answer.inspect
    assert_equal({ "root" => absent, "directories" => [], "resolved" => false,
                   "relayed" => { "runner" => "0199-h", "state" => "confirmed", "booted_at" => "2026-09-17T06:00:00Z", "resolved" => true } },
      answer.fetch("environment"))
    relayed = api.loop_creates.select { |body| body.dig("agent_loop", "steps", 0, "tool", "name") == "environment_bind" }
    assert_equal absent, relayed.fetch(0).dig("agent_loop", "steps", 0, "tool", "input", "root")
    assert_includes api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text"), absent, "the lead names the bound root"

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "runner_executor_public_id" => "0199-h",
                                  "environment" => { "root" => Rho.root } })
    assert_equal ["422", "protected_root"], [code, answer.dig("error", "code")], "a protected root is this host's to refuse"
  end

  # THE CHILD EDGE: a spawned child new to the listing gets the
  # parent's tuple written top-down on ITS store, the parent's anchor
  # unchanged, so a child answered elsewhere inherits too.
  def test_a_spawned_child_new_to_the_listing_gets_the_parents_record_top_down
    child = { "public_id" => "c-child", "title" => nil, "answering_user_public_id" => "peer-1", "archived_at" => nil,
              "billing_subject" => nil, "parent" => { "public_id" => "c-1", "spawn_node_key" => "r2t0", "label" => nil },
              "forked_from_turn_public_id" => nil, "forked_from_variant_public_id" => nil, "side" => false,
              "active_turn_public_id" => nil, "context_revision" => 0, "last_activity_at" => nil,
              "created_at" => "2026-09-12T00:00:00Z", "updated_at" => "2026-09-12T00:00:00Z" }
    events = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS + [
      { "public_id" => "ev-3", "sequence" => 3, "cursor" => "c3", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-06T00:00:01Z",
        "payload" => { "status" => "completed", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" } },
    ]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: -> { api.conversation_inputs.empty? ? [] : events })
    api.stock_children("c-1", [child])
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    src = project("src")

    open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text", "environment" => { "root" => src } })
    wait_for { record_of(api, "c-child") }

    assert_equal({ "root" => src, "directories" => [], "anchor" => "c-1" }, record_of(api, "c-child").fetch("value"),
      "the parent's tuple, the parent's anchor")

    daemon.home.write_setting("workspace", "ws-2")
    assert_equal "ws-1", daemon.loops.host_workspace("c-child")
    assert_nil daemon.loops.host_binding("c-child"), "scope does not attach the child"
    assert_nil store.find("c-child")
    assert_equal ["c-1"], followed(daemon).map { |row| row.fetch("public_id") }
    core = Rho::Core.new(home: daemon.home)
    assert_equal false, core.stop("c-child").fetch("followed")
    error = assert_raises(Rho::Core::Refused) { core.say("c-child", "a new request") }
    assert_equal "host_not_followed", error.code

    # The parent alone is re-adopted. Its durable feed restores the child
    # listing; no child attachment is invented on this boot either.
    daemon.stop
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-2")
    wait_for { daemon.loops.host_workspace("c-child") == "ws-1" }
    assert_equal ["c-1"], followed(daemon).map { |row| row.fetch("public_id") }
    assert_equal ["c-1"], store.rows.map(&:host_public_id)
    assert_equal false, Rho::Core.new(home: daemon.home).stop("c-child").fetch("followed")
    cancellations = api.requests.map(&:first).grep(%r{/conversations/c-child/cancellation\z})
    assert_equal ["/agent_api/v1/workspaces/ws-1/conversations/c-child/cancellation"] * 2, cancellations
  end
end
