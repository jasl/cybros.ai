require "support/daemon_loop_helpers"

class DaemonLoopsTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  # FAIL-CLOSED: a hook that raises refuses the open, names itself, and
  # nothing reached the kernel.
  def test_an_author_hook_that_raises_refuses_the_open_and_nothing_is_created
    path = File.join(@root, "boom.rb")
    File.write(path, <<~RUBY)
      module BoomAuthorExtension
        NAME = "rho.boom"
        def self.register(api)
          api.on(:turn_author) { |_draft, _ctx| raise "no turns today" }
        end
      end
    RUBY
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: Rho::Config.from_hash("extension_paths" => [path])), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "500", code
    assert_equal "extension_failed", answer.dig("error", "code")
    assert_match(/rho\.boom failed while authoring the turn \(RuntimeError\)/, answer.dig("error", "message"))
    assert_empty api.conversation_creates
    assert_empty store.rows
  end

  # A Refusal a hook answers is relayed as itself.
  def test_a_refusal_a_hook_answers_is_relayed
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    code, answer = open(daemon, { "prompt" => "p", "model" => "m/x", "until" => { "command" => "t", "attempts" => 0 } })
    assert_equal ["400", "malformed_body"], [code, answer.dig("error", "code")]
    assert_empty api.conversation_creates
  end

  # A hook sees the draft's lead and the resolved model, and what it
  # answers is what the turn opens with and what the row remembers.
  def test_an_author_hook_shapes_the_lead_and_the_notes
    path = File.join(@root, "motto.rb")
    File.write(path, <<~RUBY)
      module MottoExtension
        NAME = "rho.motto"
        def self.register(api)
          api.on(:turn_author) do |draft, _ctx|
            draft.with(lead: draft.lead + "\\n\\nMotto: measure twice.",
              notes: draft.notes.merge(NAME => { "model" => draft.body.fetch("model") }))
          end
        end
      end
    RUBY
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: Rho::Config.from_hash("extension_paths" => [path],
      "default_model" => "dev/mock-text")), api)

    code, = open(daemon, { "prompt" => "p" })

    assert_equal "201", code
    assert api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text").end_with?("Motto: measure twice.")
    assert_equal({ "rho.motto" => { "model" => "dev/mock-text" } }, store.rows.fetch(0).notes)
  end

  # FAIL-OPEN: a follow hook that raises costs its gate, never the
  # follower; and it is fired with the LOOP id, once the feed names it.
  def test_a_follow_hook_is_given_the_loop_id_and_one_that_raises_costs_the_gate_not_the_follower
    path = File.join(@root, "gateless.rb")
    File.write(path, <<~RUBY)
      module GatelessExtension
        NAME = "rho.gateless"
        def self.register(api)
          api.on(:turn_follow) do |loop_public_id, _notes, _ctx|
            File.write(#{File.join(@root, "seen.txt").inspect}, loop_public_id)
            raise "no gate today"
          end
        end
      end
    RUBY
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: Rho::Config.from_hash("extension_paths" => [path])), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    refute answer.fetch("run").key?("until")
    assert_equal "al-1", File.read(File.join(@root, "seen.txt"))
    assert_equal ["c-1"], followed(daemon).map { |row| row.fetch("public_id") }
  end

  # THE HOST ENDED HERE: a host this
  # daemon stops following — its `conversation_ended` item, its 404, a
  # handoff away, every one of them `Loops#forget` — fires `:host_ended`
  # with the host's public id to every subscriber, ONCE per end, in
  # registration order, fail-OPEN: a subscriber that raises costs nothing
  # but its own log line — not the next subscriber, and never the release
  # of the processes that host's loops started, which runs first.
  def test_a_host_that_ends_here_fires_host_ended_once_with_its_public_id_fail_open
    seen = File.join(@root, "ended.txt")
    boom = host_ended_extension("boom.rb", "rho.boom", 'raise "no release today"')
    keeper = host_ended_extension("keeper.rb", "rho.keeper", "File.open(#{seen.inspect}, \"a\") { |f| f.puts host_public_id }")
    daemon = boot(config: Rho::Config.from_hash("extension_paths" => [boom, keeper]))
    process = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call, loop: "c-1")

    daemon.loops.forget(conversation_host("c-1"))

    assert_equal ["c-1"], File.readlines(seen, chomp: true), "the subscriber after the raising one is told, once"
    wait_for { daemon.host.processes.row("p1").nil? }
    refute process.live?
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=host_ended_hook_failed .*extension=rho\.boom .*host=c-1 .*error_class=RuntimeError/, log)
    refute_includes log, "loops.host_ended_failed", "the release and the other subscriber never learned of the raise"

    daemon.loops.forget(loop_host("al-7"))
    assert_equal %w[c-1 al-7], File.readlines(seen, chomp: true), "a standalone loop's end is a host's end too"
  end

  def test_a_completed_standalone_loop_releases_its_resources_but_keeps_its_final_snapshot
    seen = File.join(@root, "ended.txt")
    hook = host_ended_extension("keeper.rb", "rho.keeper", "File.open(#{seen.inspect}, \"a\") { |file| file.puts host_public_id }")
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    original = api.method(:call)
    events = []
    api.define_singleton_method(:call) do |path, **arguments|
      if path.end_with?("/agent_loops/al-1/events")
        CybrosAgent::Response.new(status: 200, headers: {}, body: {
          "events" => events, "pagination" => { "next_after" => nil, "watermark" => events.length },
        })
      else
        original.call(path, **arguments)
      end
    end
    daemon = member_ready(boot(config: Rho::Config.from_hash("extension_paths" => [hook])), api)
    host = loop_host("al-1")
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    process = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call, loop: host.public_id)
    capturing_spawns(daemon) do
      daemon.loops.remember(host, workspace: "ws-1")
      daemon.loops.adopt_run(host, host.context(workspace), {}, loops: workspace.agent_loops)
    end
    run = daemon.context.run(host.public_id)
    events << { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "turn_status",
                "resource" => { "type" => "agent_loop", "public_id" => host.public_id },
                "occurred_at" => "2026-10-01T00:00:00Z", "payload" => { "status" => "completed", "loop_status" => "completed" } }

    run.follow

    listing = followed(daemon)
    assert_equal [host.public_id], listing.map { |row| row.fetch("public_id") }, "completion keeps its snapshot readable"
    assert_same run, daemon.context.run(host.public_id)
    row = listing.fetch(0)
    assert_equal [host.public_id, "completed", true], row.values_at("public_id", "status", "complete")
    assert_predicate run, :stopped?, "a retained snapshot keeps no subscriptions open"
    assert_nil store.find(host.public_id), "a restart must not re-follow the completed loop"
    assert_equal [host.public_id], File.readlines(seen, chomp: true)
    wait_for { daemon.host.processes.row("p1").nil? }
    refute process.live?

    daemon.loops.forget(host)
    assert_nil daemon.context.run(host.public_id), "explicit forgetting still drops the retained snapshot"
    assert_empty followed(daemon)
  end

  # A RUNNER-MODE HOST follows no conversation, so it has no end to fire
  # (the parity with the processes table's own gap, stated): the
  # registration answers the base handle's `unavailable`, logged, and the
  # extension loads all the same.
  def test_host_ended_is_unavailable_on_a_runner_mode_host_not_a_load_error
    path = host_ended_extension("releaser.rb", "rho.releaser", "nil")
    daemon = boot(config: Rho::Config.from_hash("mode" => "runner", "extension_paths" => [path]))

    assert_nil daemon.loops, "a runner-mode daemon builds no Loops"
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=extension_verb_unavailable .*extension=rho\.releaser .*hook host_ended is not surfaced by a standalone runner/, log)
    refute_includes log, "extension_load_failed"
  end

  def host_ended_extension(file, name, body)
    path = File.join(@root, file)
    File.write(path, <<~RUBY)
      module #{name.split(".").last.capitalize}HostEndedExtension
        NAME = #{name.inspect}
        def self.register(api)
          api.on(:host_ended) do |host_public_id|
            #{body}
          end
        end
      end
    RUBY
    path
  end

  # A LINEAGE THAT DIED between the create and the follow refuses the run,
  # and the answer says so: no follower is reported that nobody holds.
  def test_a_run_the_lineage_refused_is_not_reported_as_followed
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE))
    loops = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1").agent_loops
    daemon.lineage.lose(about: daemon.lineage.credentials)

    assert_nil daemon.loops.adopt_run(loop_host("al-9"), loops.agent_loop("al-9"), {})
    assert_empty daemon.lineage.runs
  end

  # RE-ADOPTION fires the follow hook per remembered row — with the loop
  # the row knew — so a gate a restart forgot is rebuilt from the notes.
  def test_re_adoption_rebuilds_the_gate_from_the_notes_on_the_loop_the_row_knew
    policy = Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @root, runner: nil, seed: {})
    variant = { "public_id" => "v-9", "source" => "agent_loop", "status" => "running",
      "agent_loop_public_id" => "al-9", "active" => true }
    turn = { "public_id" => "t-9", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
      "status" => "running", "visibility" => "visible", "inherited" => false,
      "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
      "active_variant" => variant }
    trace = NexusDoubles::RUNNING_TRACE.merge(
      "turn" => { "public_id" => "t-9", "conversation_public_id" => "c-9", "status" => "running" })
    api = NexusDoubles::FakeAgentApi.new(trace: trace, conversation_events: [], conversation_event_head: 42,
      conversation_busy: "t-9", turns: [turn],
      variants: { "turn" => { "public_id" => "t-9", "inherited" => false }, "variants" => [variant] })
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-9"), workspace: "ws-1", turn: "t-9", loop: "al-9",
      notes: { "rho.until" => policy.to_h.merge("loop_public_id" => "al-9") })

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    row = followed(daemon).fetch(0)
    assert_equal %w[c-9 al-9 t-9], [row.fetch("public_id"), row.fetch("loop"), row.fetch("turn")]
    assert_equal "al-9", row.dig("until", "loop"), "the gate came back bound to the row's loop"
    assert(api.appends.any?, "the check was hung below the loop's first round")
    assert_equal ["al-9"], store.rows.map(&:loop), "the row is re-followed, never forgotten"
  end

  # A daemon that restarts follows nothing. Every loop it authored kept
  # advancing on the server with nobody watching — and only `--until` loops
  # were remembered, which is how the general case stayed missing while its
  # special case worked.
  def test_a_remembered_loop_is_followed_again_after_a_restart
    trace = NexusDoubles::HALTED_TRACE.merge("status" => "running", "attention" => nil)

    api = NexusDoubles::FakeAgentApi.new(trace: trace)
    daemon = member_ready(boot, api)
    store.remember(loop_host("al-9"), workspace: "ws-1")
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["al-9"], followed(daemon).map { |row| row.fetch("public_id") }
  end

  # A loop that finished while nobody was watching is not re-followed, and
  # its row goes — otherwise every boot re-reads a graveyard. A conversation
  # never finishes by itself: its row stands and its feed is followed again.
  def test_a_terminal_loop_is_forgotten_and_a_conversation_is_followed_again
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE.merge("status" => "completed"))
    daemon = member_ready(boot, api)
    store.remember(loop_host("al-9"), workspace: "ws-1")
    store.remember(conversation_host("c-9"), workspace: "ws-1", loop: "al-8", model: "m/x")
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["c-9"], followed(daemon).map { |row| row.fetch("public_id") }
    assert_equal %w[c-9], store.rows.map(&:host_public_id), "the loop's row is gone; the conversation's stands"
  end

  # Workspace selection does not retire another remembered host of this identity.
  def test_re_adoption_restores_rows_in_their_original_workspace
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)
    store.remember(loop_host("al-elsewhere"), workspace: "ws-other")
    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["al-elsewhere"], followed(daemon).map { |row| row.fetch("public_id") }
    assert api.requests.any? { |entry| entry.first.include?("/workspaces/ws-other/agent_loops/al-elsewhere") }
    assert_equal %w[al-elsewhere], store.rows.map(&:host_public_id)
  end
end
