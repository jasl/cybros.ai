require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "rho"
require "securerandom"
require "stringio"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/executor_relay_helpers"
require "support/red_square_png"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/steward_session"

# THE REQUEST HALF OF THE EXECUTOR RELAY. A member asks ONE runner for something only it can answer
# as a ONE-TASK STANDALONE LOOP on the task-grained surface: a single `tool` step under `raw`, the
# runner named, created AND STARTED, claimed and committed through the runner's own doors, the loop
# completed by the settle, the answer read on the task. `rho call_tool RUNNER TOOL [INPUT]` is the verb,
# driven through exe/rho: the daemon composes it through the SDK (`request` → `request_result`) with
# the rules `rho do` authors re-addressed to the seed's own origin.
#
# The world, three grants: a rho with the shipped set (it serves no tool; its `rho
# ps`/`rho logs` read a bound runner's table through the relay), an environment host on a second home
# (the shipped runner set: `files_bytes` and `process_log` announced described to nobody beside the
# model's tools — runner capabilities), and a harness RUNNER-kind process announcing `read`,
# `capture` (its commit door stages the red square and commits `title` + `metadata`, the settled
# terminal fixture (a)7 needs) and the guarded `bash` echo (a name the deny rules address, (a)9);
# the dead-runner case (a)4 kills and restarts the harness process, whose restart on the same
# credential is the proven shape.
#
# ONE CEREMONY PER FILE: the steward's session, the two daemons (their own
# homes) and the runner's grant are booted once for every case here.
class ExecutorRelayTest < Minitest::Test
  include E2E::ExecutorRelayHelpers

  REGISTRATION_IDENTIFIER = "cybros-e2e-relay-runner".freeze
  RUNNER_DISPLAY_NAME = "E2E relay runner".freeze
  RUNNER_TOOLS = %w[read capture bash].freeze
  TOOL_CALL_KEY = "call_tool".freeze
  # 2 MiB: over `snapshot_bound` and `read`'s own 50 KB truncation.
  BIG_LINE = ("x" * 63) + "\n"
  BIG_LINES = 32_768
  PNG = E2E::RedSquarePng.bytes

  World = Struct.new(:daemon, :home, :runner_rho, :runner_rho_home, :runner_id, :runner_home, :harness_root, :steward,
    :actor, :workspace_public_id, :runner, :project, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-executor-relay-e2e")
      runner_rho_home = Dir.mktmpdir("rho-executor-relay-runner-e2e")
      runner_home = Dir.mktmpdir("e2e-relay-runner")
      # Relay refusal compares the complete Run list; unrelated title cleanup must not change it.
      File.write(File.join(home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(conversation_title_model: nil, plugins: { "e2e.tool-catalog-author" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.expand_path("../support/tool_catalog_author.rb", __dir__) } } })), perm: 0o600)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, runner_rho_home: runner_rho_home, runner_home: runner_home,
        steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      boot_runner_rho!(base_url, actor)
      E2E.enable_dev_lane!
      E2E.hosts.start
      grant_runner!(base_url, actor)
      daemon.control(:get, "/runners")
      @world
    end

    # A product test host serves the real environment and process tools on
    # an independent executor address, without a second rho application.
    def boot_runner_rho!(base_url, actor)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        registration_identifier: "e2e-relay-environment-#{SecureRandom.hex(6)}", runner_display_name: "Relay environment")
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization)
      credentials = device.await_credentials(authorization)
      @world.runner_rho = E2E::ExecutorProcess.new(base_url: base_url, home: @world.runner_rho_home,
        credential: credentials.executor_access_token, world: @world.runner_rho_home, captured_directories: true).start
      @world.runner_id = @world.runner_rho.executor_public_id
    end

    # THE GRANT, then the process: a RUNNER kind — the row a request names as its binding; the
    # transport credential comes only through the browser ceremony a person completes and reaches
    # the child on stdin.
    def grant_runner!(base_url, actor)
      device = CybrosAgent::DeviceFlow::Client.new(base_url: base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = device.request_runner_authorization(
        registration_identifier: REGISTRATION_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME, executor_kind: "runner"
      )
      E2E::RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      offer = E2E::RunnerGrant.scope_offer(actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      E2E::RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
      credentials = device.await_credentials(authorization)
      # THE ANNOUNCED ROOT: the harness runner names where its relative paths resolve, so a turn a
      # rho opens on it has a lead to render — the environment lane's "the lead names its announced
      # root" reads that very sentence.
      @world.harness_root = File.join(@world.runner_home, "root").tap { |dir| FileUtils.mkdir_p(dir) }
      @world.runner = E2E::ExecutorProcess.new(base_url: base_url, home: @world.runner_home,
        credential: credentials.executor_access_token, kind: :runner, tools: RUNNER_TOOLS,
        environment: @world.harness_root)
      @world.runner.start
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

      { "the runner process" => world.runner, "the environment host" => world.runner_rho,
        "the rho daemon" => world.daemon }.each do |label, process|
        process&.stop
      rescue StandardError => error
        warn "Could not stop #{label}: #{error.class}: #{error.message}"
      end
      [world.home, world.runner_rho_home, world.runner_home, world.project].each do |dir|
        FileUtils.remove_entry(dir) if dir && File.directory?(dir)
      end
    end
  end

  Minitest.after_run { ExecutorRelayTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @runner_rho = @world.runner_rho
    @runner_id = @world.runner_id
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @runner = @world.runner
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    assert_equal "runner", @runner.announced_kind
    assert_equal RUNNER_TOOLS.sort, @runner.announced.sort
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
    warn_log(@runner_rho&.log_path, "environment host stdout")
    warn_log(@runner&.log_path, "runner process log")
  rescue StandardError => error
    warn "Could not capture the executor relay E2E logs: #{error.class}: #{error.message}"
  end

  # (a)2: a conversation on the environment host starts a server through
  # `rho do --runner` (the mock calls what it is told); the process is
  # CONVERSATION-owned there. On the AGENT daemon `rho ps` lists it
  # through a relayed `list_processes` (the row ends in its runner; `ps`
  # fans out over every remote runner, whatever their count) and
  # `rho logs ID --runner R` reads its tail through `process_log` — the
  # person's read with no owner gate; the honest `remote:` line is gone.
  # TWO REMOTE RUNNERS BY CONSTRUCTION: since E1 this class follows hosts
  # bound to the environment host AND to the harness runner, in whatever
  # order the seed runs its cases, so before the logs read a throwaway
  # conversation is bound onto the harness runner HERE — the daemon then
  # follows hosts on two remote runners regardless of seed, and the bare
  # `rho logs ID` REFUSES naming the flag (routes.rb `log_document` /
  # `not_found`: ONE remote runner is inferred, several need `--runner`).
  # Before E1 the class had one bound remote runner, so the bare read held
  # by construction alone, never as a pin; the inference's own unit pin is
  # rho's processes_test. The contrast: the model's `read_process`,
  # relayed, is REFUSED by ownership — the recorded semantic difference
  # between the two tools.
  def test_rho_ps_and_rho_logs_read_a_conversation_owned_process_on_the_environment_host_through_the_relay
    loop_id = rho_do(script([runner_tool("start_process"), { "command" => "sleep 300", "name" => "svc" }]), runner: @runner_id)
    completed = await_run_status(loop_id, "completed")
    started = completed.tasks.find { |task| task.kind == "tool_task" && task.tool_name == "start_process" }
    refute_nil started, "the mock never called start_process: #{completed.tasks.map(&:tool_name).inspect}"
    answer = loops.run(loop_id).task(started.key).output.to_s
    id = answer[/\A(p\d+) \(pid \d+\) running/, 1]
    refute_nil id, "start_process did not report a running process:\n#{answer}"
    assert_includes @runner_rho.claimed_keys, started.key, "the environment host's runner started it"

    listing, ps_status = @daemon.cli("ps")
    assert_predicate ps_status, :success?, "rho ps failed:\n#{listing}"
    assert_match(/^#{id}  running  pid \d+  owner \S+  run \S+  svc  \(.*\)  runner #{Regexp.escape(@runner_id)}$/,
      listing, "the row lives on the environment host and says so")
    refute_match(/its processes live there, not in this table/, listing, "the honest line is gone: the rows are here")
    assert(@runner_rho.claims.any? { |claim| claim["tool"] == "list_processes" },
      "`rho ps` read the table through a relayed list_processes: #{@runner_rho.claims.inspect}")

    # The second remote runner, bound by construction (nothing bound under
    # `--dir`: E1 (b)'s shape, on the harness runner); its loop completes
    # before the read so the store row is a followed host's, not a race.
    _, bound_loop, = open_bound("!mock -- hello there", dir: nil, runner: @runner.executor_public_id)
    await_run_status(bound_loop, "completed")

    # THE ROUTING RULE (routes.rb `log_document` / `not_found`): an id this
    # machine's table does not know is asked of the ONE remote runner the
    # followed hosts are bound to; with SEVERAL nothing is inferred and the
    # 404 names the flag that picks a table.
    bare, bare_status = @daemon.cli("logs", id, "--tail", "5")
    refute_predicate bare_status, :success?, "two remote runners: the bare read must refuse, not guess:\n#{bare}"
    assert_includes bare, "no process #{id} here; name a runner's table with --runner", bare

    log, logs_status = @daemon.cli("logs", id, "--tail", "5", "--runner", @runner_id)
    assert_predicate logs_status, :success?, "rho logs failed:\n#{log}"
    assert_match(/^#{id}  running  pid \d+  owner \S+  run \S+  svc  \(.*\)  runner #{Regexp.escape(@runner_id)}$/, log)
    assert_match(%r{^log: \S+/processes/#{id}\.log$}, log, "the environment host's own log file")
    assert(@runner_rho.claims.any? { |claim| claim["tool"] == "process_log" },
      "`rho logs` read the row through a relayed process_log: #{@runner_rho.claims.inspect}")

    refused, refused_status = relay(@runner_id, "read_process", JSON.generate("id" => id))
    assert_predicate refused_status, :success?, "a tool that RAN and refused is data, not a failed request:\n#{refused}"
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, refused)
    assert_match(/#{id} \(svc\) belongs to conversation \S+; only its runs, or the person \(rho kill #{id}\), may read it/, refused,
      "the model's read_process is gated by ownership; a relay loop is a standalone caller with none")
  end

  # (a)3: a 2 MiB file — the runner's `read` truncates it as it does today,
  # `files_bytes` on the same file captures it WHOLE, and a `Range` on the
  # one bytes read answers `206` with the tail: HTTP's own chunked read.
  def test_read_truncates_a_two_megabyte_file_and_files_bytes_captures_it_whole_for_a_ranged_read
    big = File.join(runner_root, "big-#{SecureRandom.hex(4)}.txt")
    File.write(big, BIG_LINE * BIG_LINES)
    size = BIG_LINE.bytesize * BIG_LINES

    read_out, read_status = relay(@runner_id, "read", JSON.generate("path" => File.basename(big)))
    assert_predicate read_status, :success?, read_out
    assert_match(/\[Showing lines 1-\d+ of #{BIG_LINES} \(.*limit\)\. Use offset=\d+ to continue\.\]/, read_out,
      "`read` keeps its own truncation")

    fb_out, fb_status = relay(@runner_id, "files_bytes", JSON.generate("path" => File.basename(big)))
    assert_predicate fb_status, :success?, fb_out
    link = fb_out[%r{^link:\s+#{Regexp.escape(File.basename(big))} \([^,]+, #{size} B\) (\S+)$}, 1]
    refute_nil link, "the whole file, captured:\n#{fb_out}"

    tail = StringIO.new
    assert_equal 206, @steward_client.uploads.bytes(link, tail, range: "bytes=#{size - 64}-").status
    assert_equal (BIG_LINE * BIG_LINES)[-64..].b, tail.string.b, "the last 64 bytes: a Range is the chunked read"
  end

  # (a)7, and the seed rule driven end to end: `rho call_tool RUNNER capture`
  # authors ONE tool step on the named runner, starts it, and prints the
  # completed task with its `title`, `metadata` and the capture's link;
  # `rho task RUN call_tool` reads the same two fields back; the runner's own
  # log claimed the key, rho's claimed nothing; the loop is one tool task,
  # completed, bound to the runner, no round ever run; the link's bytes
  # read through `rho fetch`.
  def test_a_relay_runs_the_named_runners_tool_as_a_one_task_loop_and_the_task_read_carries_title_and_metadata
    output, status = relay(@runner.executor_public_id, "capture", "{}")
    assert_predicate status, :success?, "rho call_tool failed:\n#{output}"
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, output)
    assert_match(/^tool:\s+capture$/, output)
    assert_match(/^title:\s+capture$/, output)
    assert_match(/^metadata:\s+\{"checkpoint":\{"step":1\},"upload_public_id":"[^"]+"\}$/, output)
    assert_match(/^echo:capture:\{\}$/, output, "the runner's own handler answered")
    link = output[%r{^link:\s+square\.png \(image/png, #{PNG.bytesize} B\) (\S+)$}, 1]
    refute_nil link, "the capture's line ends in the id `rho fetch` takes:\n#{output}"

    assert_includes @runner.claimed_keys, TOOL_CALL_KEY, "the runner process took the row: #{@runner.log_text}"
    assert_empty @daemon.claimed_keys, "the agent daemon serves no tool and claimed nothing"

    task_output, task_status = @daemon.cli("task", loop_id, TOOL_CALL_KEY)
    assert_predicate task_status, :success?, task_output
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, task_output)
    assert_match(/^title:\s+capture$/, task_output)
    assert_match(/^metadata:\s+\{"checkpoint":\{"step":1\}/, task_output)

    run = loops.fetch(loop_id)
    assert_equal "completed", run.status, "quiescence completed the loop on the settle"
    assert_equal TOOL_CALL_KEY, run.deliverable_task_key, "the one step is the answer"
    assert_equal ["tool_task"], run.tasks.map(&:kind), "one task, no round, no summarizer"
    assert_equal @runner.executor_public_id, run.deliverable.target.executor_public_id, "the task keeps its explicit target"
    assert_equal @runner.executor_public_id, run.deliverable.claimed_by.executor_public_id
    assert_equal "author", run.deliverable.approval.fetch("origin"), "granted by its origin"
    assert_equal "raw", run.prompt_mechanism, "a standalone loop: the shell's word was raw"

    bytes, fetch_status = @daemon.cli_bytes("fetch", link)
    assert_predicate fetch_status, :success?
    assert_equal PNG, bytes, "the relayed capture reads back whole through `rho fetch`"
  end

  # (a)9: `rm -rf /` relayed to the runner is DENIED by the rules the verb
  # passes — the same list `rho do` authors, re-addressed to the seed's
  # `author` origin — at the stage, before dispatch: the runner never
  # claims it, the verb prints the rule's own sentence, the loop is stopped.
  def test_a_relay_of_a_guarded_command_is_denied_by_the_rules_the_verb_passes
    output, status = relay(@runner.executor_public_id, "bash", JSON.generate("command" => "rm -rf /"))
    refute_predicate status, :success?, output
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output
    assert_match(/^task:\s+call_tool \(tool_task\) failed$/, output)
    assert_match(/^error:\s+approval_denied — recursive delete of a root directory$/, output)
    assert_match(/^input:\s+\{"command":"rm -rf \/"\}$/, output)

    refute(@runner.since_start.any? { |line| line["event"] == "runner_task_claimed" && line["tool"] == "bash" },
      "denied before dispatch: the runner never saw it — #{@runner.log_text}")
    assert_equal "canceled", await_run_status(loop_id, "canceled").status
    assert_equal "failed", loops.fetch(loop_id).deliverable.status, "the settled row keeps its word"
  end

  # ---- THE CONVERSATION'S ENVIRONMENT ON A RUNNER ELSEWHERE ----

  def test_an_environment_host_restart_uses_the_next_tasks_captured_directory_immediately
    sub = bound_subdirectory
    File.write(File.join(runner_root, "probe.txt"), "default root\n")
    File.write(File.join(sub, "probe.txt"), "bound root\n")
    conversation, loop_id, = open_bound(script([runner_tool("read"), { "path" => "probe.txt" }]), dir: sub, runner: @runner_id)
    assert_includes tool_answer(await_run_status(loop_id, "completed"), "read"), "bound root"
    restart_environment_host!

    chat = @steward_client.workspace(@workspace_public_id).conversation(conversation)
    after = chat.turns.list.items.map(&:position).max || -1
    chat.inputs.create(kind: "direct_reply", model: MODEL, text: script(*([[runner_tool("read"), { "path" => "probe.txt" }]] * 2)),
      executor_contexts: { @runner_id => { "rho.environment" => { "root" => sub, "directories" => [], "anchor" => conversation } } },
      idempotency_key: SecureRandom.uuid)
    reply = await("no reply settled to the person's own read on #{conversation}") do
      newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
      failed = newer.find { |turn| turn.status == "failed" }
      flunk "the reply failed: #{failed.to_h.inspect}" if failed
      newer.find { |turn| turn.status == "completed" }
    end
    row = loops.fetch(reply.active_variant.run_public_id)
    assert_includes tool_answer(row, "read"), "bound root", "a fresh Runner needs no environment relay"
    read = row.tasks.find { |task| task.tool_name == "read" }
    assert_equal sub, loops.run(row.public_id).task(read.key).executor_context.dig("rho.environment", "root")

    marker = "after the restart #{SecureRandom.hex(4)}"
    await_run_status(say_loop(conversation, script(*([note("after.txt", marker)] * 3))), "completed")
    assert_equal "#{marker}\n", File.read(File.join(sub, "after.txt"), encoding: Encoding::UTF_8)
    refute_path_exists File.join(runner_root, "after.txt")
  end

  # A child may already have its own binding when a restarted host discovers
  # the children again. The inherited copy loses to that row; the runner must
  # use the winning child's tuple when the host authors its next turn.
  def test_a_restarted_host_preserves_a_spawned_childs_own_environment_on_the_remote_runner
    parent_root = bound_subdirectory
    child_root = bound_subdirectory
    conversation, loop_id, = open_bound(
      script(["spawn", { "role" => "worker", "prompt" => "!mock -- child ready", "label" => "bound-child", "wait" => true }]),
      dir: parent_root, runner: @runner_id
    )
    chat = @steward_client.workspace(@workspace_public_id).conversation(conversation)
    child = await("the parent never spawned bound-child") do
      chat.children.items.find { |row| row.parent&.label == "bound-child" }
    end
    child_chat = @steward_client.workspace(@workspace_public_id).conversation(child.public_id)
    first = await("the child never finished its opening turn") do
      child_chat.turns.list.items.find { |turn| turn.role == "assistant" && turn.status == "completed" }
    end
    await_run_status(first.active_variant.run_public_id, "completed")
    await_run_status(loop_id, "completed")
    refute child_chat.fetch.busy?, "the child is idle before its binding is changed"

    copy = await("the host never copied the parent's binding") { binding_summary(child.public_id) }
    own_binding = { "root" => child_root, "directories" => [], "anchor" => child.public_id }
    store(child.public_id).update(copy.public_id, value: own_binding, lock_version: copy.lock_version)

    @daemon.stop
    FileUtils.rm_f(File.join(@world.home, "tmp", "announcement.json"))
    @daemon.start
    self.class.await_workspace_adopted(@daemon)
    attached, status = @daemon.cli("attach", child.public_id, "--conversation")
    assert_predicate status, :success?, attached

    marker = "child keeps its root #{SecureRandom.hex(4)}"
    filename = "own-root-#{SecureRandom.hex(4)}.txt"
    say_loop(child.public_id, script(note(filename, marker)))
    reply = await("the child's next turn never completed") do
      newer = child_chat.turns.list.items.select { |turn| turn.position > first.position && turn.role == "assistant" }
      failed = newer.find { |turn| turn.status == "failed" }
      flunk "the child's reply failed: #{failed.to_h.inspect}" if failed
      newer.find { |turn| turn.status == "completed" }
    end
    row = await_run_status(reply.active_variant.run_public_id, "completed")
    refute_nil row.tasks.find { |task| task.tool_name == "write" && task.status == "completed" },
      "the child's real runner executed the write: #{row.tasks.map(&:to_h).inspect}"
    assert_equal own_binding, store(child.public_id).fetch(copy.public_id).value,
      "the inherited copy never overwrote the child's stored binding"
    assert File.file?(File.join(child_root, filename)), "the write must land under the child's own root"
    assert_equal "#{marker}\n", File.read(File.join(child_root, filename), encoding: Encoding::UTF_8)
    refute File.exist?(File.join(parent_root, filename)), "the restart must not restore the parent's runtime binding"
  end
end
