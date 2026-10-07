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
# The world, three grants: an AGENT-mode rho with the shipped set (it serves no tool; its `rho
# ps`/`rho logs` read a bound runner's table through the relay), a RUNNER-mode rho on a second home
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
      File.write(File.join(home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: { "e2e.tool-catalog-author" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.expand_path("../support/tool_catalog_author.rb", __dir__) } } })), perm: 0o600)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_MODE" => "agent" })
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

    # THE RUNNER HALF ON A SECOND HOME (r-modes M1): `RHO_MODE=runner` with
    # the shipped set, branch B alone, one plane, no workspace — announced
    # before anything could be addressed to it. Its runner row's id is what
    # `rho call_tool`, `rho do --runner` and `rho ps` name.
    def boot_runner_rho!(base_url, actor)
      runner_rho = E2E::RhoDaemon.new(base_url: base_url, home: @world.runner_rho_home, env: { "RHO_MODE" => "runner" })
      @world.runner_rho = runner_rho
      runner_rho.start
      started = runner_rho.start_ceremony
      raise "a runner-mode rho pairs branch B alone: #{started.inspect}" unless started["branch"] == "runner"

      E2E::Ceremony.confirm(actor: actor, started: started, status: -> { runner_rho.status })
      runner_rho.await_announced(address: "runner")
      @world.runner_id = runner_rho.status.dig("identity", "runner_executor_public_id") ||
        raise("the runner-mode rho's identity is its runner row: #{runner_rho.status.inspect}")
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

      { "the runner process" => world.runner, "the runner-mode rho" => world.runner_rho,
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
    warn_log(@runner_rho&.log_path, "runner-mode rho stdout")
    warn_log(@runner_rho&.rho_log_path, "runner-mode rho structured log")
    warn_log(@runner&.log_path, "runner process log")
  rescue StandardError => error
    warn "Could not capture the executor relay E2E logs: #{error.class}: #{error.message}"
  end

  # (a)1: `rho call_tool RUNNER files_bytes` on the AGENT daemon — the runner-
  # mode rho's `files_bytes` names the file and its run stages it as a
  # capture (the ONE upload site, `TaskRun#submit`), linked beside the
  # sentence; the loop was STARTED (completed, one node), the runner-mode
  # rho's log claimed it, the agent's claimed nothing, `rho fetch` prints
  # the file's bytes, `rho graph` draws one node.
  def test_files_bytes_relayed_to_the_runner_mode_rho_answers_a_capture_of_its_file
    note = File.join(runner_root, "note-#{SecureRandom.hex(4)}.txt")
    words = "hello from the runner #{SecureRandom.hex(8)}\n"
    File.write(note, words)

    output, status = relay(@runner_id, "files_bytes", JSON.generate("path" => File.basename(note)))
    assert_predicate status, :success?, "rho call_tool failed:\n#{output}"
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, output
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, output)
    assert_match(/^tool:\s+files_bytes$/, output)
    assert_match(/^#{Regexp.escape(note)} \(text\/plain; charset=utf-8, #{words.bytesize} bytes\)$/, output,
      "the tool's own sentence: the path a model could `read` on the same runner")
    # The link's type is the KERNEL's word: the bytes decide it, no name
    # hint reaches Marcel (`ContentUploads::Create`), so plain text stages
    # as `application/octet-stream` — the runner's own line above says
    # `text/plain` from the name; two classifiers, one file, recorded.
    link = output[%r{^link:\s+#{Regexp.escape(File.basename(note))} \(application/octet-stream, #{words.bytesize} B\) (\S+)$}, 1]
    refute_nil link, "the capture's line ends in the id `rho fetch` takes:\n#{output}"

    assert(@runner_rho.claims.any? { |claim| claim["tool"] == "files_bytes" },
      "the runner-mode rho's own log says it took the row: #{@runner_rho.claims.inspect}")
    assert_empty @daemon.claimed_keys, "the agent daemon serves no tool and claimed nothing"

    agent_run = loops.fetch(loop_id)
    assert_equal "completed", agent_run.status, "quiescence completed the loop on the settle"
    assert_equal ["tool_task"], agent_run.tasks.map(&:kind), "one task, no round, no summarizer"
    assert_equal @runner_id, agent_run.deliverable.target.executor_public_id, "the task keeps its explicit target"
    assert_equal @runner_id, agent_run.deliverable.claimed_by.executor_public_id

    detail = loops.run(loop_id).task(TOOL_CALL_KEY)
    kinds = detail.content.map { |block| block.fetch("type") }
    assert_equal %w[text resource_link], kinds, detail.content.inspect
    assert_equal "nexus://uploads/#{link}", detail.content.last.fetch("uri")
    assert_equal words.bytesize, detail.content.last.fetch("size")

    bytes, fetch_status = @daemon.cli_bytes("fetch", link)
    assert_predicate fetch_status, :success?
    assert_equal words.b, bytes, "the relayed capture reads back whole through `rho fetch`"

    graph, graph_status = @daemon.cli("graph", loop_id, "--json")
    assert_predicate graph_status, :success?, graph
    assert_equal 1, JSON.parse(graph).fetch("nodes").length, "one node: the request is the whole run"
  end

  # (a)2: a conversation on the runner-mode rho starts a server through
  # `rho do --runner` (the mock calls what it is told); the process is
  # CONVERSATION-owned there. On the AGENT daemon `rho ps` lists it
  # through a relayed `list_processes` (the row ends in its runner; `ps`
  # fans out over every remote runner, whatever their count) and
  # `rho logs ID --runner R` reads its tail through `process_log` — the
  # person's read with no owner gate; the honest `remote:` line is gone.
  # TWO REMOTE RUNNERS BY CONSTRUCTION: since E1 this class follows hosts
  # bound to the runner-mode rho AND to the harness runner, in whatever
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
  def test_rho_ps_and_rho_logs_read_a_conversation_owned_process_on_the_runner_mode_rho_through_the_relay
    loop_id = rho_do(script([runner_tool("start_process"), { "command" => "sleep 300", "name" => "svc" }]), runner: @runner_id)
    completed = await_run_status(loop_id, "completed")
    started = completed.tasks.find { |task| task.kind == "tool_task" && task.tool_name == "start_process" }
    refute_nil started, "the mock never called start_process: #{completed.tasks.map(&:tool_name).inspect}"
    answer = loops.run(loop_id).task(started.key).output.to_s
    id = answer[/\A(p\d+) \(pid \d+\) running/, 1]
    refute_nil id, "start_process did not report a running process:\n#{answer}"
    assert_includes @runner_rho.claimed_keys, started.key, "the runner-mode rho's runner started it"

    listing, ps_status = @daemon.cli("ps")
    assert_predicate ps_status, :success?, "rho ps failed:\n#{listing}"
    assert_match(/^#{id}  running  pid \d+  owner \S+  run \S+  svc  \(.*\)  runner #{Regexp.escape(@runner_id)}$/,
      listing, "the row lives on the runner-mode rho and says so")
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
    assert_match(%r{^log: \S+/processes/#{id}\.log$}, log, "the runner-mode rho's own log file")
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

  # (a)6, the local short-circuit: the runner-mode rho's own `rho ps` reads
  # its own table with NO loop created — the workspace's loop list is the
  # same before and after, and its runner claimed nothing for it.
  # The runner's claim count once it stops moving: two equal reads a second
  # apart, or the last one after the bound.
  def settled_claim_count(bound: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + bound
    last = @runner_rho.claims.length
    loop do
      sleep 1
      now = @runner_rho.claims.length
      return now if now == last || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      last = now
    end
  end

  def test_a_daemons_own_ps_reads_its_own_table_with_no_loop
    # The snapshot is taken once this world is quiet: an earlier case's
    # claim landing inside the window reads as a relayed read this verb
    # never made (the gate saw 20 where 19 stood, 2026-09-22).
    before = loops.list(order: "desc", limit: 100).items.map(&:public_id)
    claims_before = settled_claim_count

    listing, status = @runner_rho.cli("processes")

    assert_predicate status, :success?, listing
    assert_equal before, loops.list(order: "desc", limit: 100).items.map(&:public_id), "no request loop was authored"
    assert_equal claims_before, @runner_rho.claims.length, "its runner served no relayed read"
  end

  # (a)8, THE NEGATIVE: the agent daemon's sealed request for a round on
  # this runner carries the runner's tools — hidden BY NAME on the agent
  # side, `files_bytes` and `process_log` are not among them — and
  # discovery serves the two without a description or a schema, so no peer
  # could author a declaration from them either.
  def test_the_runners_person_facing_tools_are_hidden_from_the_models_list_and_undescribed_in_discovery
    loop_id = rho_do("!mock -- say hello", runner: @runner_id)
    completed = await_run_status(loop_id, "completed")
    round = completed.tasks.find { |task| task.kind == "model_task" }
    refute_nil round, completed.tasks.map(&:kind).inspect

    sealed = loops.run(loop_id).tasks_context(round.key).request
    names = Array(sealed.request_options["tools"]).filter_map { |tool| tool.dig("function", "name") || tool["name"] }
    definitions = loops.run(loop_id).task(round.key).tool_definitions
    declared = definitions.map { |tool| tool.dig("function", "name") || tool["name"] }
    %w[read bash list_processes read_process].each do |name|
      assert_includes declared, runner_tool(name), "the Runner's callable is retained in frozen authority"
      refute_includes names, runner_tool(name), "its schema is deferred from the provider request"
    end
    %w[files_bytes process_log].each do |name|
      refute_includes names, name, "hidden by name on the agent side: #{names.inspect}"
      refute_includes declared, name
      refute definitions.any? { |tool| tool.dig("route", "tool_name") == name },
        "person-facing helpers are absent from the full callable authority under every alias"
    end

    served = @steward_client.executors.show(@runner_id).served_tools.to_h { |tool| [tool.name, tool] }
    %w[files_bytes process_log].each do |name|
      tool = served.fetch(name) { flunk "#{name} is not announced by the runner-mode rho: #{served.keys.inspect}" }
      assert_nil tool.description, "#{name} describes itself to nobody"
      assert_nil tool.input_schema, "#{name} announces no schema"
    end
    refute_nil served.fetch("read").description, "the model's tools keep their declaration facts"
    refute_nil served.fetch("read").input_schema
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

    agent_run = loops.fetch(loop_id)
    assert_equal "completed", agent_run.status, "quiescence completed the loop on the settle"
    assert_equal TOOL_CALL_KEY, agent_run.deliverable_task_key, "the one step is the answer"
    assert_equal ["tool_task"], agent_run.tasks.map(&:kind), "one task, no round, no summarizer"
    assert_equal @runner.executor_public_id, agent_run.deliverable.target.executor_public_id, "the task keeps its explicit target"
    assert_equal @runner.executor_public_id, agent_run.deliverable.claimed_by.executor_public_id
    assert_equal "author", agent_run.deliverable.approval.fetch("origin"), "granted by its origin"
    assert_equal "raw", agent_run.prompt_mechanism, "a standalone loop: the shell's word was raw"

    bytes, fetch_status = @daemon.cli_bytes("fetch", link)
    assert_predicate fetch_status, :success?
    assert_equal PNG, bytes, "the relayed capture reads back whole through `rho fetch`"
  end

  # A name the Runner never announced is refused at acceptance, before
  # any rule or dispatch. The verb prints the refusal without creating a
  # Run or a dangling Task for a later stop to clean up.
  def test_a_relay_of_a_tool_nobody_serves_is_refused_without_accepting_a_run
    before = loops.list(order: "desc", limit: 100).items.map(&:public_id)
    output, status = relay(@runner.executor_public_id, "nosuch", "{}")
    refute_predicate status, :success?, "an unserved tool is refused:\n#{output}"
    assert_match(/Refused: tool_not_served/, output)
    refute_match(/^run:/, output, "acceptance refused before a Run existed")
    refute_match(/^task:/, output, "no Task was accepted for the unserved tool")

    assert_equal before, loops.list(order: "desc", limit: 100).items.map(&:public_id),
      "a refused call leaves no Run or dangling Task"
    refute_includes @runner.since_start.map { |line| line["tool"] }, "nosuch"
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

  # (a)4: the runner KILLED, a relay with its own 5 s clock. The row is
  # dispatched and never claimed; the operator backdates the park and
  # sweeps — no wall minute — and the task settles `timed_out`
  # (`tool_timeout`) with NO claimant; the daemon's `request_result`
  # answers that terminal task, the verb prints it and fails, and the
  # Run is stopped: `rho runs` lists it `canceled`. Presence is
  # never read — the sweep's clock is the only thing that settles it.
  def test_a_relay_to_a_dead_runner_is_swept_timed_out_at_its_own_deadline_and_the_loop_is_stopped
    @runner.kill!
    io = @daemon.cli_background("call_tool", @runner.executor_public_id, "read", JSON.generate("path" => "note.txt"),
      "--timeout", "5000")
    loop_id = await("the relay never dispatched its row") do
      loops.list(status: "running", order: "desc", limit: 10).items.map(&:public_id).find do |candidate|
        row = loops.fetch(candidate)
        task = row.task(TOOL_CALL_KEY)
        task && task.status == "dispatched" && row.tasks.one? && task.tool_name == "read" &&
          task.addressed_to&.executor_public_id == @runner.executor_public_id
      end
    end
    dispatched = loops.fetch(loop_id).task(TOOL_CALL_KEY)
    assert_nil dispatched.claimed_by, "nobody is alive to claim it"
    assert_equal @runner.executor_public_id, dispatched.addressed_to.executor_public_id

    E2E.operator.expire_park!(loop_id, TOOL_CALL_KEY)
    E2E.operator.sweep_park_timeouts!

    output = io.read.force_encoding(Encoding::UTF_8).scrub
    io.close
    status = $?
    refute_predicate status, :success?, output
    assert_equal loop_id, output[/^run:\s+(\S+)/, 1], output
    assert_match(/^task:\s+call_tool \(tool_task\) timed_out$/, output)
    assert_match(/^error:\s+tool_timeout$/, output)
    assert_match(/the request timed_out: tool_timeout/, output)

    task = loops.fetch(loop_id).task(TOOL_CALL_KEY)
    assert_equal "timed_out", task.status
    assert_equal "tool_timeout", task.error.fetch("key")
    assert_nil task.claimed_by, "never claimed: the sweep, not a runner, settled it"
    assert_equal "canceled", await_run_status(loop_id, "canceled").status, "stopped behind the timeout"
    listing, list_status = @daemon.cli("runs", "--status", "canceled")
    assert_predicate list_status, :success?, listing
    assert_match(/^#{Regexp.escape(loop_id)}\s+canceled/, listing, "the kernel's truth lists the request loop")
  ensure
    @runner.start if @runner && @runner.pid.nil?
  end

  # ---- THE CONVERSATION'S ENVIRONMENT ON A RUNNER ELSEWHERE ----

  # E1 (a): `rho-dev do --dir <the runner-mode rho's root>/sub --runner R`. The HOST resolves and
  # the runner is TOLD over the executor relay as the hidden runner tool `environment_bind`: the
  # runner-mode rho's log carries the claim and `environment.received`, the host's carries
  # `environment.relayed`, `do`'s answer says `relayed: confirmed`, and the turn's relative `write`
  # lands under the bound root THERE — no `environment.unresolved` on the runner's log for this
  # conversation.
  def test_a_conversation_bound_under_the_runner_mode_rhos_root_is_relayed_and_its_write_lands_there
    sub = bound_subdirectory
    marker = "relayed #{SecureRandom.hex(4)}"
    conversation, loop_id, output = open_bound(script(note("note.txt", marker)), dir: sub, runner: @runner_id)
    assert_match(/^relayed:\s+#{Regexp.escape(@runner_id)} confirmed\b/, output,
      "the verb says what the runner knows:\n#{output}")
    await_run_status(loop_id, "completed")

    assert_equal "#{marker}\n", File.read(File.join(sub, "note.txt"), encoding: Encoding::UTF_8),
      "the relative write landed under the bound root on the runner-mode rho"
    assert(@runner_rho.claims.any? { |claim| claim["tool"] == "environment_bind" },
      "the runner-mode rho's own log took the bind row: #{@runner_rho.claims.inspect}")
    refute_empty environment_lines(@runner_rho, "environment.received", naming: conversation),
      "the runner logged what it was told: #{@runner_rho.log_text}"
    refute_empty environment_lines(@daemon, "environment.relayed", naming: conversation),
      "the host logged the relay: #{@daemon.log_text}"
    assert_empty environment_lines(@runner_rho, "environment.unresolved", naming: conversation),
      "a root the runner has resolves: no window"
  end

  # E1 (b): A ROOT THE RUNNER DOES NOT HAVE (a root absent on the runner's host). One machine, so
  # the door's own validation cannot stage it: the DEBUGGING spelling of what the door does,
  # `rho-dev call_tool R environment_bind '{…}'`, binds a directory that exists nowhere — the tool
  # applies it and answers `resolved: false` (a refusal would be data; an unserved name, a failed
  # request); the next turn's relative `write` lands on PLACEMENT ZERO, the runner's default root,
  # with `environment.unresolved` on its log, and nothing under the absent root.
  def test_a_binding_whose_root_is_absent_on_the_runner_is_applied_unresolved_and_places_at_zero
    conversation, loop_id, = open_bound("!mock -- hello", dir: nil, runner: @runner_id)
    await_run_status(loop_id, "completed")
    absent = File.join(runner_root, "gone-#{SecureRandom.hex(4)}")

    output, status = relay(@runner_id, "environment_bind", JSON.generate(
      "conversation_public_id" => conversation, "root" => absent, "directories" => [], "anchor" => conversation
    ))
    assert_predicate status, :success?, "the bind tool ran and answered:\n#{output}"
    assert_match(/^task:\s+call_tool \(tool_task\) completed$/, output)
    assert_match(/^tool:\s+environment_bind$/, output)
    assert_match(/"applied":\s*true/, output, "applied, and honest about the root:\n#{output}")
    assert_match(/"resolved":\s*false/, output, output)
    refute_empty environment_lines(@runner_rho, "environment.received", naming: conversation)

    marker = "zero #{SecureRandom.hex(4)}"
    loop2 = say_loop(conversation, script(note("zero.txt", marker)))
    await_run_status(loop2, "completed")
    assert_equal "#{marker}\n", File.read(File.join(runner_root, "zero.txt"), encoding: Encoding::UTF_8),
      "placement zero: the runner's default root"
    refute File.exist?(absent), "nothing was created under the absent root"
    refute_empty environment_lines(@runner_rho, "environment.unresolved", naming: conversation),
      "the runner said so: #{@runner_rho.log_text}"
  end

  # E1 (c): THE RUNNER'S PROCESS LIFE IS THE KEY. The runner-mode rho RESTARTED mid-conversation
  # forgets its received table — no runner-side cache, by design. A scripted `read` with a relative
  # path BEFORE the host's next edge — the person's own input through the SDK, which the daemon does
  # not author — lands under the runner's default root with `environment.unresolved` on its log: the
  # stated window, bounded by a turn or a cycle. Then `rho say` refreshes discovery, reads the new
  # `booted_at`, logs `environment.relayed` again with it, and the turn's relative `write` lands
  # under the bound root.
  def test_a_runner_mode_rho_restarted_mid_conversation_is_re_relayed_at_the_next_say_and_the_window_between_is_placement_zero
    sub = bound_subdirectory
    File.write(File.join(runner_root, "probe.txt"), "default root\n")
    File.write(File.join(sub, "probe.txt"), "bound root\n")
    conversation, loop_id, = open_bound(script([runner_tool("read"), { "path" => "probe.txt" }]), dir: sub, runner: @runner_id)
    row = await_run_status(loop_id, "completed")
    assert_includes tool_answer(row, "read"), "bound root", "before the restart: the bound root"
    before = environment_lines(@daemon, "environment.relayed", naming: conversation)
    refute_empty before, @daemon.log_text
    booted_before = before.last["booted_at"]
    refute_nil booted_before, "the relay is keyed by the runner's boot: #{before.last.inspect}"

    restart_runner_rho!

    chat = @steward_client.workspace(@workspace_public_id).conversation(conversation)
    after = chat.turns.list.items.map(&:position).max || -1
    chat.inputs.create(kind: "direct_reply", model: MODEL, text: script(*([[runner_tool("read"), { "path" => "probe.txt" }]] * 2)),
      idempotency_key: SecureRandom.uuid)
    reply = await("no reply settled to the person's own read on #{conversation}") do
      newer = chat.turns.list.items.select { |turn| turn.position > after && turn.role == "assistant" }
      failed = newer.find { |turn| turn.status == "failed" }
      flunk "the reply failed: #{failed.to_h.inspect}" if failed
      newer.find { |turn| turn.status == "completed" }
    end
    window = loops.fetch(reply.active_variant.run_public_id)
    assert_includes tool_answer(window, "read"), "default root", "THE WINDOW: placement zero until the host's next edge"
    refute_empty environment_lines(@runner_rho, "environment.unresolved", naming: conversation),
      "the runner said so: #{@runner_rho.log_text}"

    marker = "after the restart #{SecureRandom.hex(4)}"
    loop3 = say_loop(conversation, script(*([note("after.txt", marker)] * 3)))
    await_run_status(loop3, "completed")
    assert_equal "#{marker}\n", File.read(File.join(sub, "after.txt"), encoding: Encoding::UTF_8),
      "re-relayed: the write lands under the bound root again"
    relayed = environment_lines(@daemon, "environment.relayed", naming: conversation)
    assert_operator relayed.length, :>, before.length, "the say relayed once more: #{relayed.inspect}"
    refute_equal booted_before, relayed.last["booted_at"], "keyed by the runner's NEW process life"
  end

  # The harness runner deliberately lacks `environment_bind`. Choosing a new
  # default retains its source-scoped record and accepted tool schemas, while
  # later turns import the newly selected Runner's exact tools.
  def test_selecting_a_default_runner_preserves_each_runners_environment_and_tool_declaration
    sub = bound_subdirectory
    conversation, loop_id, = open_bound("!mock -- hello there", dir: sub, runner: @runner.executor_public_id)
    row = await_run_status(loop_id, "completed")
    round = row.tasks.find { |task| task.kind == "model_task" }
    refute_nil round, row.tasks.map(&:kind).inspect
    assert_includes loops.run(loop_id).task(round.key).output.to_s,
      "Relative paths resolve against #{@world.harness_root}.", "the lead names the runner's announced root"
    assert_equal 1, environment_lines(@daemon, "environment.unrelayed", naming: conversation).length,
      "unrelayed, once: #{@daemon.log_text}"
    await_run_status(say_loop(conversation, "!mock -- once more"), "completed")
    assert_equal 1, environment_lines(@daemon, "environment.unrelayed", naming: conversation).length,
      "once per (conversation, runner), not per turn"
    entry = binding_summary(conversation, runner: @runner.executor_public_id)
    refute_nil entry, "the open wrote the record"
    original = store(conversation).fetch(entry.public_id)

    selected, status = @daemon.cli("set_default_runner", conversation, @runner_id)
    assert_predicate status, :success?, "different Runner schemas can coexist:\n#{selected}"
    assert_equal @runner_id,
      @steward_client.workspace(@workspace_public_id).conversation(conversation).fetch.default_runner.executor_public_id,
      "the nullable default applies to future acceptance"
    assert_equal entry.lock_version, store(conversation).fetch(entry.public_id).lock_version,
      "changing the default never rewrites another Runner's environment"
    assert_equal original.value, store(conversation).fetch(entry.public_id).value
    assert_nil binding_summary(conversation), "a default selection does not copy an environment onto another Runner"
    assert_empty environment_lines(@daemon, "environment.relayed", naming: conversation)
      .select { |line| line.values.include?(@runner_id) }, "no environment was authored for the newly selected Runner"
    assert_empty environment_lines(@runner_rho, "environment.received", naming: conversation),
      "the runner-mode rho was told nothing: #{@runner_rho.log_text}"

    note = File.join(sub, "selected.txt")
    File.write(note, "the newly selected Runner\n")
    prompt = script([runner_tool("read"), { "path" => note }])
    continued = await_run_status(say_loop(conversation, prompt), "completed")
    read = continued.tasks.find { |task| task.tool_name == "read" }
    refute_nil read, "the selected Runner's callable is available"
    assert_equal @runner_id, read.target.executor_public_id
    assert_equal @runner_id, read.claimed_by.executor_public_id
    assert_includes tool_answer(continued, "read"), "the newly selected Runner", "the newly selected Runner executed the call"

    model = continued.tasks.find { |task| task.kind == "model_task" }
    surfaces = {
      @runner.executor_public_id => loops.run(loop_id).task(round.key).tool_definitions,
      @runner_id => loops.run(continued.public_id).task(model.key).tool_definitions,
    }
    bash = surfaces.map do |runner, definitions|
      assert_equal [runner], definitions.filter_map { |tool| tool.dig("route", "runner_executor_public_id") }.uniq,
        "each accepted surface contains only its selected Runner"
      declaration = definitions.find { |tool| tool.dig("route", "tool_name") == "bash" }
      refute_nil declaration, "the selected Runner retains its bash declaration"
      served = @steward_client.executors.show(runner).served_tools.find { |tool| tool.name == "bash" }
      assert_equal served.input_schema, declaration.dig("function", "parameters")
      assert_equal runner_tool("bash", runner: runner), declaration.dig("function", "name")
      declaration
    end
    assert_equal 2, bash.map { |tool| tool.dig("function", "parameters") }.uniq.length,
      "the two served schemas remain distinct"
    assert_equal 1, environment_lines(@daemon, "environment.unrelayed", naming: conversation).length,
      "the original environment still logs its unsupported relay only once"
  end

  # E1 (e), REMOTE CHILD EXECUTION: a spawned child on the REMOTE runner. The kernel's inbox row
  # carries `parent_public_id` — the child's parent, the snapshot the kernel keeps — so the runner
  # resolves the child's environment by its PARENT's received binding with no relay in the path: the
  # child's relative `write` lands under the parent's root with no `environment.unresolved` for the
  # child, and the host's top-down copy appears in the child's own store with the parent's anchor.
  def test_a_spawned_child_on_the_remote_runner_resolves_its_environment_by_its_parents_binding
    sub = bound_subdirectory
    marker = "from the child #{SecureRandom.hex(4)}"
    brief = script(note("child.txt", marker))
    # Join here so this shared world has no later reply loop racing the
    # local processes test's before/after loop listing.
    conversation, loop_id, = open_bound(script(["spawn", { "prompt" => brief, "label" => "helper", "wait" => true }]),
      dir: sub, runner: @runner_id)
    chat = @steward_client.workspace(@workspace_public_id).conversation(conversation)
    child = await("no child labelled helper under #{conversation}") do
      chat.children.items.find { |row| row.parent&.label == "helper" }
    end
    child_chat = @steward_client.workspace(@workspace_public_id).conversation(child.public_id)
    assert_equal @runner_id, child_chat.fetch.default_runner.executor_public_id, "the child copied the parent's bound runner"
    reply = await("the child never replied") do
      turns = child_chat.turns.list.items.select { |turn| turn.role == "assistant" }
      failed = turns.find { |turn| turn.status == "failed" }
      flunk "the child's reply failed: #{failed.to_h.inspect}" if failed
      turns.find { |turn| turn.status == "completed" }
    end
    child_loop = loops.fetch(reply.active_variant.run_public_id)
    write = child_loop.tasks.find { |task| task.tool_name == "write" }
    refute_nil write, "the child never called write: #{child_loop.tasks.map(&:to_h).inspect}"
    assert_equal "completed", write.status, write.to_h.inspect

    assert_equal "#{marker}\n", File.read(File.join(sub, "child.txt"), encoding: Encoding::UTF_8),
      "the child's relative write landed under the PARENT's root on the runner-mode rho"
    assert_empty environment_lines(@runner_rho, "environment.unresolved", naming: child.public_id),
      "resolved by the parent's binding through the row's parent_public_id: no window"
    copy = await("the host never copied the record to the child's store") { binding_summary(child.public_id) }
    value = store(child.public_id).fetch(copy.public_id).value
    assert_equal({ "root" => sub, "directories" => [], "anchor" => conversation }, value,
      "the parent's tuple, the parent's anchor")
    await_run_status(loop_id, "completed")
  end

  # A child may already have its own binding when a restarted host discovers
  # the children again. The inherited copy loses to that row; the runner must
  # receive the winning child's tuple too, before a member posts its next turn.
  def test_a_restarted_host_preserves_a_spawned_childs_own_environment_on_the_remote_runner
    parent_root = bound_subdirectory
    child_root = bound_subdirectory
    conversation, loop_id, = open_bound(
      script(["spawn", { "prompt" => "!mock -- child ready", "label" => "bound-child", "wait" => true }]),
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
    relayed_before = environment_lines(@daemon, "environment.relayed", naming: child.public_id).length

    @daemon.stop
    FileUtils.rm_f(File.join(@world.home, "tmp", "announcement.json"))
    @daemon.start
    await("the restarted parent follower never relayed its rediscovered child") do
      environment_lines(@daemon, "environment.relayed", naming: child.public_id).length > relayed_before
    end

    marker = "child keeps its root #{SecureRandom.hex(4)}"
    filename = "own-root-#{SecureRandom.hex(4)}.txt"
    child_chat.inputs.create(kind: "direct_reply", model: MODEL, text: script(note(filename, marker)),
      idempotency_key: SecureRandom.uuid)
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
