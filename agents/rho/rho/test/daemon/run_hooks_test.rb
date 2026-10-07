require "support/daemon_run_helpers"

class DaemonHostFollowersTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

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
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "plugins" => { "rho.boom" => RhoTest.described_extension(path, id: "rho.boom") } })), api)

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
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "plugins" => { "rho.motto" => RhoTest.described_extension(path, id: "rho.motto") },
      "default_model" => "dev/mock-text" })), api)

    code, = open(daemon, { "prompt" => "p" })

    assert_equal "201", code
    assert api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text").end_with?("Motto: measure twice.")
    assert_equal({ "rho.motto" => { "model" => "dev/mock-text" } }, store.rows.fetch(0).notes)
  end

  # FAIL-OPEN: a follow hook that raises costs its gate, never the
  # follower; and it is fired with the RUN id, once the feed names it.
  def test_a_follow_hook_is_given_the_run_id_and_one_that_raises_costs_the_gate_not_the_follower
    path = File.join(@root, "gateless.rb")
    File.write(path, <<~RUBY)
      module GatelessExtension
        NAME = "rho.gateless"
        def self.register(api)
          api.on(:turn_follow) do |run_public_id, _notes, _ctx|
            File.write(#{File.join(@root, "seen.txt").inspect}, run_public_id)
            raise "no gate today"
          end
        end
      end
    RUBY
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "plugins" => { "rho.gateless" => RhoTest.described_extension(path, id: "rho.gateless") } })), api)

    code, answer = open(daemon, { "prompt" => "fix it", "model" => "dev/mock-text" })

    assert_equal "201", code, answer.inspect
    refute answer.fetch("run").key?("until")
    # The feed can fire the hook on the reactor after the response. Capture a
    # completed write instead of reading between File.write's truncate and write.
    seen = nil
    path = File.join(@root, "seen.txt")
    wait_for { File.exist?(path) && !(seen = File.read(path)).empty? }
    assert_equal "al-1", seen
    assert_equal ["c-1"], followed(daemon).map { |row| row.fetch("public_id") }
  end

  # THE HOST ENDED HERE: a host this
  # daemon stops following — its `conversation_ended` item, its 404, a
  # set_default_runner away, every one of them `HostFollowers#forget` — fires `:host_ended`
  # with the host's public id to every subscriber, ONCE per end, in
  # registration order, fail-OPEN: a subscriber that raises costs nothing
  # but its own log line — not the next subscriber, and never the release
  # of the processes that host's runs started, which runs first.
  def test_a_host_that_ends_here_fires_host_ended_once_with_its_public_id_fail_open
    seen = File.join(@root, "ended.txt")
    boom = host_ended_extension("boom.rb", "rho.boom", 'raise "no release today"')
    keeper = host_ended_extension("keeper.rb", "rho.keeper", "File.open(#{seen.inspect}, \"a\") { |f| f.puts host_public_id }")
    daemon = boot(config: Rho::Config.from_hash({ "plugins" => { "rho.boom" => boom, "rho.keeper" => keeper } }))
    process = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call, run_public_id: "c-1")

    daemon.host_followers.forget(conversation_host("c-1"))

    assert_equal ["c-1"], File.readlines(seen, chomp: true), "the subscriber after the raising one is told, once"
    wait_for { daemon.host.processes.row("p1").nil? }
    refute process.live?
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_match(/event=host_ended_hook_failed .*extension=rho\.boom .*host=c-1 .*error_class=RuntimeError/, log)
    refute_includes log, "runs.host_ended_failed", "the release and the other subscriber never learned of the raise"

    daemon.host_followers.forget(run_host("al-7"))
    assert_equal %w[c-1 al-7], File.readlines(seen, chomp: true), "a standalone run's end is a host's end too"
  end

  def test_a_completed_standalone_run_releases_its_resources_but_keeps_its_final_snapshot
    seen = File.join(@root, "ended.txt")
    hook = host_ended_extension("keeper.rb", "rho.keeper", "File.open(#{seen.inspect}, \"a\") { |file| file.puts host_public_id }")
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    original = api.method(:call)
    events = []
    api.define_singleton_method(:call) do |path, **arguments|
      if path.end_with?("/runs/al-1/events")
        CybrosAgent::Response.new(status: 200, headers: {}, body: {
          "events" => events, "pagination" => { "next_after" => nil, "watermark" => events.length },
        })
      else
        original.call(path, **arguments)
      end
    end
    daemon = member_ready(boot(config: Rho::Config.from_hash({ "plugins" => { "rho.keeper" => hook } })), api)
    host = run_host("al-1")
    workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
    process = daemon.host.processes.start(command: "sleep 30", workdir: @root, env: Rho::Runner::ChildEnv.call, run_public_id: host.public_id)
    capturing_spawns(daemon) do
      daemon.host_followers.remember(host, workspace: "ws-1")
      daemon.host_followers.adopt_follower(host, host.context(workspace), {}, runs: workspace.runs)
    end
    run = daemon.context.follower(host.public_id)
    events << { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "turn_status",
                "resource" => { "type" => "run", "public_id" => host.public_id },
                "occurred_at" => "2026-10-01T00:00:00Z", "payload" => { "status" => "completed", "run_status" => "completed" } }

    run.follow

    listing = followed(daemon)
    assert_equal [host.public_id], listing.map { |row| row.fetch("public_id") }, "completion keeps its snapshot readable"
    assert_same run, daemon.context.follower(host.public_id)
    row = listing.fetch(0)
    assert_equal [host.public_id, "completed", true], row.values_at("public_id", "status", "complete")
    assert_predicate run, :stopped?, "a retained snapshot keeps no subscriptions open"
    assert_nil store.find(host.public_id), "a restart must not re-follow the completed run"
    assert_equal [host.public_id], File.readlines(seen, chomp: true)
    wait_for { daemon.host.processes.row("p1").nil? }
    refute process.live?

    daemon.host_followers.forget(host)
    assert_nil daemon.context.follower(host.public_id), "explicit forgetting still drops the retained snapshot"
    assert_empty followed(daemon)
  end

  # A RUNNER-MODE HOST follows no conversation, so it has no end to fire
  # (the parity with the processes table's own gap, stated): the
  # registration answers the base handle's `unavailable`, logged, and the
  # extension loads all the same.
  def test_host_ended_is_unavailable_on_a_runner_mode_host_not_a_load_error
    path = host_ended_extension("releaser.rb", "rho.releaser", "nil")
    daemon = boot(config: Rho::Config.from_hash({ "mode" => "runner", "plugins" => { "rho.releaser" => path } }))

    assert_nil daemon.host_followers, "a runner-mode daemon builds no HostFollowers"
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
    RhoTest.described_extension(path, id: name)
  end

  # A LINEAGE THAT DIED between the create and the follow refuses the run,
  # and the answer says so: no follower is reported that nobody holds.
  def test_a_run_the_lineage_refused_is_not_reported_as_followed
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE))
    runs = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1").runs
    daemon.lineage.lose(about: daemon.lineage.credentials)

    assert_nil daemon.host_followers.adopt_follower(run_host("al-9"), runs.run("al-9"), {})
    assert_empty daemon.lineage.followers
  end

  # RE-ADOPTION fires the follow hook per remembered row — with the run
  # the row knew — so a gate a restart forgot is rebuilt from the notes.
  def test_re_adoption_rebuilds_the_gate_from_the_notes_on_the_run_the_row_knew
    policy = Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @root, runner: nil, seed: {})
    variant = { "public_id" => "v-9", "source" => "run", "status" => "running",
      "run_public_id" => "al-9", "active" => true }
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
    store.remember(conversation_host("c-9"), workspace: "ws-1", turn: "t-9", run_public_id: "al-9",
      notes: { "rho.until" => policy.to_h.merge("run_public_id" => "al-9") })

    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    row = followed(daemon).fetch(0)
    assert_equal %w[c-9 al-9 t-9], [row.fetch("public_id"), row.fetch("run_public_id"), row.fetch("turn")]
    assert_equal "al-9", row.dig("until", "run_public_id"), "the gate came back bound to the row's run"
    assert_empty api.appends, "the original input already accepted its check"
    assert_equal ["al-9"], store.rows.map(&:run_public_id), "the row is re-followed, never forgotten"
  end

  # A daemon that restarts follows nothing. Every run it authored kept
  # advancing on the server with nobody watching — and only `--until` runs
  # were remembered, which is how the general case stayed missing while its
  # special case worked.
  def test_a_remembered_run_is_followed_again_after_a_restart
    trace = NexusDoubles::HALTED_TRACE.merge("status" => "running", "attention" => nil)

    api = NexusDoubles::FakeAgentApi.new(trace: trace)
    daemon = member_ready(boot, api)
    store.remember(run_host("al-9"), workspace: "ws-1")
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["al-9"], followed(daemon).map { |row| row.fetch("public_id") }
  end

  # A run that finished while nobody was watching is not re-followed, and
  # its row goes — otherwise every boot re-reads a graveyard. A conversation
  # never finishes by itself: its row stands and its feed is followed again.
  def test_a_terminal_run_is_forgotten_and_a_conversation_is_followed_again
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE.merge("status" => "completed"))
    daemon = member_ready(boot, api)
    store.remember(run_host("al-9"), workspace: "ws-1")
    store.remember(conversation_host("c-9"), workspace: "ws-1", run_public_id: "al-8", model: "m/x")
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["c-9"], followed(daemon).map { |row| row.fetch("public_id") }
    assert_equal %w[c-9], store.rows.map(&:host_public_id), "the run's row is gone; the conversation's stands"
  end

  # Workspace selection does not retire another remembered host of this identity.
  def test_re_adoption_restores_rows_in_their_original_workspace
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::HALTED_TRACE)
    daemon = member_ready(boot, api)
    store.remember(run_host("al-elsewhere"), workspace: "ws-other")
    daemon.host_followers.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["al-elsewhere"], followed(daemon).map { |row| row.fetch("public_id") }
    assert api.requests.any? { |entry| entry.first.include?("/workspaces/ws-other/runs/al-elsewhere") }
    assert_equal %w[al-elsewhere], store.rows.map(&:host_public_id)
  end
end
