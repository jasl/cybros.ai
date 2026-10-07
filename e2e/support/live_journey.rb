require "support/actor_provisioning"
require "support/ceremony"
require "support/browser_actor"
require "support/rho_daemon"
require "support/provider_lanes"
require "support/rate_limited"
require "support/secret_hygiene"
require "support/steward_session"
require "support/evals/bench"
require "support/evals/report_line"
require "support/evals/sealed_request"
require "support/evals/trace"
require "tmpdir"

module E2E
  # A run the HARNESS ended: the deadline, or the cost stop. `why` is the
  # record's `stopped` word (the evals lane's) and the live lanes' red
  # line. One class for every paid lane: the evals lane's drivers rescue
  # it, a live lane's teardown prints its report line under it.
  class Stopped < StandardError
    attr_reader :why

    def initialize(why, message)
      @why = why
      super(message)
    end
  end

  # WHAT EVERY PAID JOURNEY DOES BEFORE IT CAN ASK A MODEL ANYTHING: bring
  # up a daemon, walk a person through the device ceremony in a real
  # browser, wait for a workspace, and price the account so a paid lane is
  # admissible at all.
  #
  # THE PROVIDER FOLLOWS THE MODEL, which is the whole reason this exists
  # as a module rather than three copies. A journey names one model —
  # `provider/reference` — and the lane it needs is the first segment of
  # that name. Hardcoding `openrouter` meant every journey silently
  # required an OpenRouter mirror, and a direct first-party lane could not
  # be run at all without editing three files identically.
  #
  # AND WHAT EVERY PAID JOURNEY OWES AFTER: a MONEY BOUND while it runs — `stop_over_cost!` off the
  # phases route's spend, polled under `await_loop_completion` and, while a CLI verb blocks, by
  # `watching_spend` — and ONE REPORT LINE per loop it awaited, through the evals scorer's reader
  # (`Evals::ReportLine`: the spend, the sealed request's bytes, the rounds, the runner meter),
  # printed at teardown whatever the verdict.
  module LiveJourney
    LOOP_DEADLINE_SECONDS = 900

    # THE LIVE LANES' PATIENCE IN MONEY: `E2E_LIVE_COST_STOP_USD` names it
    # for a run; else the bench's — `limits.cost_stop_usd` ($8), and a
    # lane the bench keys by task name takes its own row (`exit-long`
    # $20, the wall lanes $12; `Bench#cost_stop_usd_for`). Never a kernel
    # ceiling: the harness `rho stop`s the conversation over it and the
    # lane is red with `stopped=cost_stop` on its report line.
    COST_STOP_ENV = Evals::Bench::COST_STOP_ENV
    # The spend is read every SPEND_POLL_EVERY polls of `await_loop_completion`
    # (3 s each); while a CLI verb blocks, every SPEND_WATCH_SECONDS.
    SPEND_POLL_EVERY = 10
    SPEND_WATCH_SECONDS = SPEND_POLL_EVERY * 3

    def self.bench = @bench ||= Evals::Bench.read

    # Paid targets are operator configuration, independent of the journey assertions.
    def self.default_models = bench.tiers.fetch(Evals::Bench::FLOOR)

    def self.default_model = default_models.fetch(0)

    def self.cost_stop_usd_for(task, env: ENV, bench: nil)
      named = env[COST_STOP_ENV].to_s.strip
      return Float(named) unless named.empty?

      (bench || self.bench).cost_stop_usd_for(task.to_s)
    end

    # The lane's own name — `LiveExitMediumTest` → `exit_medium`, the
    # sweep's word for it — the report line's task when the lane names no
    # bench task of its own.
    def self.lane_name(klass)
      klass.name.to_s.split("::").last.delete_prefix("Live").delete_suffix("Test")
        .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    # Called from `setup`. Skips rather than fails when the lane this
    # journey's model needs is not configured on this machine (a provider
    # `ProviderLanes` has no key for, or a key unset here). `task:` is
    # the bench's name for the lane when it has one (`exit-long`,
    # `compaction-wall-long`): the cost stop's key and the report line's
    # task column.
    # `models:` names every model the world will serve when it is more than
    # the one this journey starts with; each one's provider is enabled.
    def start_live_journey!(model_ref, home_prefix:, daemon_env: {}, task: nil, models: [model_ref])
      skip "live journeys are opt-in (E2E_LIVE=1)" unless ENV["E2E_LIVE"] == "1"

      key_name = ProviderLanes.key_name_for(model_ref)
      @live_provider_keys = ProviderLanes.provider_keys_for([model_ref, *models])
      @live_provider_keys.each do |provider, name|
        skip "no e2e lane is configured for provider #{provider.inspect}" if name.nil?
        skip "#{name} is not set" if ENV[name].to_s.empty?
      end

      @live_key_name = key_name
      @live_model = model_ref
      @live_task = task || LiveJourney.lane_name(self.class)
      @cost_stop_usd = LiveJourney.cost_stop_usd_for(@live_task)
      @settled_loops = {}
      @reported_loops = []
      @base_url = E2E.base_url
      @world = E2E::ActorProvisioning.world(@base_url)
      @steward = @world.rho_steward
      # ONE SIGNED-IN STEWARD BROWSER PER PROCESS (`StewardSession`): the
      # sign-in is memoised per (server, Human), a grant of the sign-in
      # ledger spent once per file instead of once per test.
      @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      @page = @actor.page
      @home = Dir.mktmpdir(home_prefix)
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: daemon_env)
      sign_in_steward
    end

    # THE DAEMON HOME BEFORE ITS BOOT: `settings.json` whole, and LOCAL adaptation rows under
    # `adaptations/` (`{id => yaml}`) — the evals lane's configuration, the sweep lane's style row —
    # read at boot, so written before `connect_and_open_lane!`.
    def write_daemon_home!(settings:, local_rows: {})
      File.write(File.join(@home, "settings.json"), JSON.generate(settings), perm: 0o600)
      local_rows.each do |id, yaml|
        FileUtils.mkdir_p(File.join(@home, "adaptations"))
        File.write(File.join(@home, "adaptations", "#{id}.yml"), yaml)
      end
    end

    def finish_live_journey!
      report_lane!
      dump_logs! unless passed? || skipped?
      @runner&.stop
      @daemon&.stop
      FileUtils.remove_entry(@home) if @home && File.directory?(@home)
      FileUtils.remove_entry(@runner_home) if @runner_home && File.directory?(@runner_home)
      # The steward's browser is the process's (`StewardSession`), closed
      # when the run ends — never per test.
    end

    # A SECOND HOME IN RUNNER MODE: `RHO_MODE=runner rho server` under the same steward — the
    # container's shape on this machine — paired on branch B alone (the machine page; a plain
    # member's page offers the private scope, which is enough: both homes are the steward's, and a
    # `user_private` runner is eligible for the Profiles its manager stewards), ready once its
    # runner address has announced. Answers its runner row's id, the thing a lane names or hands off
    # to. One more device-authorization unit; no second sign-in. `daemon:` builds the runner over
    # the fresh home when the runner-mode rho is not a second process on this machine — a container
    # (`E2E::Evals::Docker::Daemon`), addressed through the same announcement and ceremony; the
    # default is the host's own. `settings:` is THIS home's `settings.json` (an extension the RUNNER
    # serves — rho-browser — is named in the runner's home, never the agent's) and `daemon_env:`
    # rides its process (the Playwright driver), both before it boots (the capture path on a
    # separated runner).
    def start_runner_rho!(home_prefix:, daemon: nil, daemon_env: {}, settings: nil)
      @runner_home = Dir.mktmpdir(home_prefix)
      File.write(File.join(@runner_home, "settings.json"), JSON.generate(settings), perm: 0o600) if settings
      @runner = daemon ? daemon.call(@runner_home) :
        E2E::RhoDaemon.new(base_url: @base_url, home: @runner_home, env: { "RHO_MODE" => "runner" }.merge(daemon_env))
      @runner.start
      started = @runner.start_ceremony
      assert_equal "runner", started["branch"], "a runner-mode rho pairs branch B alone: #{started.inspect}"
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { @runner.status })
      @runner.await_announced(address: "runner")
      runner_id = @runner.status.dig("identity", "runner_executor_public_id")
      refute_nil runner_id, "the runner-mode rho's identity is its runner row: #{@runner.status.inspect}"
      runner_id
    end

    # A PAID FAILURE MUST BE DIAGNOSABLE THE FIRST TIME. These runs cost
    # money and take a minute each, and an intermittent one — a round that
    # sits `running` and never moves — is exactly the failure that will
    # not reproduce on demand. The daemon's stdout says what rho did; the
    # HOSTS' logs say what happened to the model call, which is where a
    # stall actually lives.
    #
    # WHY THAT MATTERS HERE SPECIFICALLY: a text-generation attempt's
    # deadline is one hour (SimpleInference::ApiFormat's
    # WORKLOAD_DEADLINE_SECONDS), so a wedged call is not reaped inside
    # any journey's patience. The 120-second stream idle timeout should
    # cut first — and if a stall outlives it, these logs are the only
    # evidence of why.
    def dump_logs!
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      warn_log(@runner&.log_path, "runner-mode rho stdout")
      warn_log(@runner&.rho_log_path, "runner-mode rho structured log")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
    end

    # Connect the daemon, price the account, open the lane, start the hosts.
    #
    # A PAID LANE NEEDS A PRICED ACCOUNT. Nothing in the product writes
    # `Account#cost_unit` — several services read it — so a fresh account
    # refuses every paid model with `unresolved_cost`, which is the kernel
    # correctly declining to spend what it cannot price. The dev lane never
    # meets this because it is free.
    def connect_and_open_lane!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      await_workspace_state("adopted")
      price_and_open_lane!
    end

    # THE WORLD'S HALF ALONE — the account priced, every model's provider enabled, the execution
    # hosts started — for a lane whose daemons are not this process's: the harbor cell's live inside
    # harbor's task containers and pair through the sidecar. Each key is REGISTERED so a dumped log
    # redacts it wherever the world's log might carry it; its value is never printed.
    def price_and_open_lane!
      E2E.operator.set_cost_unit!("USD")
      @live_provider_keys.each do |provider, name|
        E2E.operator.enable_provider!(provider, E2E::SecretHygiene.register(ENV.fetch(name)))
      end
      E2E.hosts.start
    end

    # The memoised session is asserted, never re-made: a test that broke
    # it fails the next setup loudly rather than signing in again silently.
    def sign_in_steward
      @actor.visit("/")
      assert @page.has_text?("Dashboard"), "the steward's session did not reach the dashboard"
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    def workspace_public_id
      @workspace_public_id ||= @daemon.status.dig("workspace", "public_id")
    end

    # THE MEMBER-PLANE CLIENT'S PATIENCE: `Net::HTTP`'s default read timeout is 60 s, and a phases
    # read of a long loop died on it (O(n²) route answered in 100–180 s) — the whole trace lost
    # although the loop completed. The open is short (the kernel is local), the read long
    # (`platform_http.rb`'s shape); every member-plane open goes through `agent_api_http`.
    AGENT_API_OPEN_TIMEOUT = 5
    AGENT_API_READ_TIMEOUT = 300

    def agent_api_http(uri, &block)
      Net::HTTP.start(uri.hostname, uri.port, open_timeout: AGENT_API_OPEN_TIMEOUT, read_timeout: AGENT_API_READ_TIMEOUT, &block)
    end

    # A member-plane read; a 429 is slept out and retried, bounded
    # (`E2E::RateLimited`, 12a L1) — the kernel's 120/min per credential is
    # a product fact this harness paces itself under, never raises.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      E2E::RateLimited.read(path) { agent_api_http(uri) { |http| http.request(request) } }
    end

    # A member-plane write, for the one thing a journey has to author itself:
    # a loop shaped to HALT, which no rho verb can create on purpose — and
    # the cost stop of a standalone loop, which no conversation verb reaches.
    def agent_api_post(path, body)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate(body)
      response = agent_api_http(uri) { |http| http.request(request) }
      [JSON.parse(response.body.to_s.empty? ? "{}" : response.body), response.code.to_i]
    end

    def loop_path(run_public_id) = "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{run_public_id}"

    def loop_row(run_public_id) = agent_api(loop_path(run_public_id)).fetch("run")

    # HOW FAR ALONG: the `phases` route (`progress` is the host's ephemeral feed, not this read).
    def phases(run_public_id) = agent_api("#{loop_path(run_public_id)}/phases")

    # `needs_attention` is TERMINAL FOR A WATCHER even though the loop is
    # alive: it means the kernel is holding for a human and will not move
    # on its own. The gem owns the terminal set.
    def settled?(row) = (CybrosAgent::Api::RUN_TERMINAL_STATUSES + ["needs_attention"]).include?(row.fetch("status"))

    # A PARK IS A REST, NOT A HALT (`AgentRuns::EvaluateQuiescence::
    # APPROVAL_REASON`: "waiting is not halting"): a call resting for an
    # approver leaves the loop `running` with `attention.reason`
    # `approval_required`, and the held call is the `tool_task` at
    # `needs_approval` — the mock's read (`approval_test`'s `await_park`).
    # The kernel's loop row names no keys (`attention: {reason}` alone;
    # `blocked_task_keys` is the daemon's followed row's), so the keys are
    # read off the tasks. A watcher that waited for `needs_attention` here
    # waited its whole deadline out (the smoke's grant lane, 900 s).
    def parked?(row) = parked_keys(row).any?

    def parked_keys(row)
      row.fetch("tasks").select { |task| task["kind"] == "tool_task" && task["status"] == "needs_approval" }
        .map { |task| task.fetch("key") }
    end

    def await_halt(run_public_id, deadline: LOOP_DEADLINE_SECONDS)
      started = monotonic
      limit = started + deadline
      loop do
        row = loop_row(run_public_id)
        if row.fetch("status") == "needs_attention" && row.dig("attention", "reason") == "halt_failure"
          return remember_settled(run_public_id, row, monotonic - started)
        end
        raise Stopped.new("deadline", "the loop never halted in #{deadline} s: #{summarize(row)}") if monotonic > limit

        sleep 2
      end
    end

    # THE HARNESS'S PATIENCE, not the kernel's: the deadline and the cost
    # stop are both `Stopped`, named on the error; a journey that kept
    # polling past `needs_attention` would burn its deadline waiting for
    # something that is waiting for it. The settled row is remembered for
    # the lane's report line.
    def await_loop_completion(run_public_id, deadline: LOOP_DEADLINE_SECONDS)
      await_loop(run_public_id, "settled", deadline: deadline) { |row| settled?(row) }
    end

    # The same wait for a lane under `--approval ask`: the row once the
    # loop settled OR a call parked (`parked?`) — the lane decides the
    # park and waits again.
    def await_loop_rest(run_public_id, deadline: LOOP_DEADLINE_SECONDS)
      await_loop(run_public_id, "settled or parked", deadline: deadline) { |row| settled?(row) || parked?(row) }
    end

    def await_loop(run_public_id, word, deadline:)
      started = monotonic
      limit = started + deadline
      polls = 0
      loop do
        row = loop_row(run_public_id)
        return remember_settled(run_public_id, row, monotonic - started) if yield(row)
        raise Stopped.new("deadline", "the loop never #{word} in #{deadline} s: #{summarize(row)}") if monotonic > limit

        stop_over_cost!(run_public_id) if ((polls += 1) % SPEND_POLL_EVERY).zero?
        sleep 3
      end
    end

    # THE COST STOP: the loop's spend off the phases route against the
    # lane's patience (`@cost_stop_usd`; nil is no bound). Over it, the
    # run is stopped — the conversation through `rho stop` (the CLI door;
    # the evals lane's opened turn first, else the one the loop row names),
    # a standalone loop through its own stop route — and the stop raised.
    def stop_over_cost!(run_public_id)
      return if @cost_stop_usd.nil?

      spent = phases(run_public_id).dig("spend", "cost_amount")
      return if spent.nil? || Float(spent) <= @cost_stop_usd

      stop_the_run!(run_public_id)
      raise Stopped.new("cost_stop", "the loop spent #{spent} over the task's #{@cost_stop_usd}: stopped")
    end

    def stop_the_run!(run_public_id)
      conversation = @conversation || loop_row(run_public_id).dig("turn", "conversation_public_id")
      return stop_conversation!(conversation) if conversation

      body, code = agent_api_post("#{loop_path(run_public_id)}/stop", {})
      puts "stop:    loop #{run_public_id} → #{code} #{body.dig("run", "status") || body.dig("error", "code")}"
    end

    def stop_conversation!(conversation)
      stopped, status = @daemon.cli("stop", conversation)
      puts "stop:    #{stopped.lines.first.to_s.strip} (#{status.success? ? "ok" : "refused"})"
    end

    # THE SPEND IS WATCHED WHILE A CLI VERB BLOCKS: a lane that sits on `rho watch` for the loop's
    # whole life would leave the cost stop unable to fire, so `stop_over_cost!` is polled beside the
    # verb every `every` seconds (each poll opens its own `Net::HTTP`) and the stop is KEPT — the
    # conversation is already stopped, which ends the verb — and raised once the verb returns, its
    # answer discarded.
    def watching_spend(run_public_id, every: SPEND_WATCH_SECONDS, &verb)
      polling_beside(every, -> { spend_poll(run_public_id) }, &verb)
    end

    # nil under the bound, or the `Stopped` the poll raised; a poll that
    # cannot read the route keeps watching (a diagnostic read).
    def spend_poll(run_public_id)
      stop_over_cost!(run_public_id)
      nil
    rescue Stopped => stop
      stop
    rescue StandardError => error
      warn "the spend poll could not read #{run_public_id}: #{error.class}: #{error.message.to_s[0, 120]}"
      nil
    end

    # ONE POLLER BESIDE A BLOCKING VERB: `poll` runs on its own thread every `every` seconds until the
    # verb returns or the poll answers something other than nil — a stop it made, which ends the verb
    # — and that answer is raised once the verb has returned. Each poll owns its failure policy (the
    # spend's read is tolerant, the evals ask attendant's is not). The poller is joined before
    # anything reads what it wrote, and a raise out of the verb — an inner poller's stop — outranks
    # the outer poller's answer.
    def polling_beside(every, poll)
      ended = Queue.new
      poller = Thread.new do
        loop do
          break nil if ended.pop(timeout: every)

          polled = poll.call
          break polled if polled
        end
      end
      begin
        answer = yield
      ensure
        ended << :ended
        held = poller.value
      end
      raise held if held

      answer
    end

    # `rho watch LOOP …` under the spend watch: the verb every lane blocks
    # on, bounded in money the way `await_loop_completion` is.
    def rho_watch(run_public_id, *arguments)
      watching_spend(run_public_id) { @daemon.cli("watch", run_public_id, *arguments) }
    end

    # The loop's spend off the phases route (`agent_runs.md:296-308`): `{input_tokens,
    # output_tokens, cost_amount, cost_unit}` — the report line's cost. nil, never a raise: the line
    # is diagnostic.
    def loop_spend(run_public_id)
      phases(run_public_id)["spend"]
    rescue StandardError
      nil
    end

    # `GET …/tasks/{key}/request` for the round `SealedRequest.key_for`
    # names — the last completed mainline round; nil when no round completed or the kernel
    # answered an error (a diagnostic read: the report line and the evals
    # trace read it on the red path too).
    def read_sealed_request(run_public_id, tasks, graph = nil)
      key = Evals::SealedRequest.key_for(tasks, mainline_keys: (Evals::Trace.mainline_keys(graph) if graph)) or return nil
      Evals::SealedRequest.from_document(agent_api(Evals::SealedRequest.path(loop_path(run_public_id), key)), key)
    rescue StandardError => error
      warn "the sealed request of #{key} could not be read: #{error.class}: #{error.message}"
      nil
    end

    # rho's runner meters on the daemon serving this lane's tools, off
    # `/status`'s `runner` block: `swept` — the sweep passes its inbox
    # reader made so far (the daemon's life: a retired runner's total is
    # carried across `rho do --dir`'s rebuild) — and `nudged`, the nudges
    # its socket carried. nil, never a raise: the columns are diagnostic.
    def runner_meter(daemon, name)
      daemon&.status&.dig("runner", name.to_s)
    rescue StandardError
      nil
    end

    def runner_swept(daemon = @daemon) = runner_meter(daemon, :swept)

    # ONE REPORT LINE PER LOOP (the evals scorer's reader): the row's rounds and calls, the phases
    # route's spend, the sealed request's BYTES, the runner meter, and the columns the lane's own
    # assertions decide — `—` where the lane read none. `events: nil` is "the feed was not read"
    # (compactions=—), never "none". Printed, and the loop marked so the teardown does not print it
    # twice.
    def report_loop!(row, task: @live_task, model: @live_model, events: nil, seconds: nil, reached: nil,
                     succeeded: nil, task_pass: nil, run: nil, stopped: nil)
      run_public_id = row && row["public_id"]
      settled = run_public_id && @settled_loops&.fetch(run_public_id, nil)
      record = Evals::ReportLine.lane(
        task: task, model: model, row: row, events: events, spend: (run_public_id && loop_spend(run_public_id)),
        sealed: (row && read_sealed_request(run_public_id, Array(row["tasks"]))), swept: runner_swept,
        seconds: seconds || settled&.fetch(:seconds)&.round, reached: reached, succeeded: succeeded,
        task_pass: task_pass, run: run || loop_ordinal(run_public_id), stopped: stopped
      )
      (@reported_loops ||= []) << run_public_id if run_public_id
      puts Evals::ReportLine.render(record)
      record
    end

    # A lane whose lines are its own records' (the evals lane) prints no
    # per-loop line at teardown.
    def reports_own_lines? = false

    # THE TEARDOWN'S LINES: every loop the lane awaited and did not report
    # itself, in the order they settled — whatever the verdict, and never
    # a raise inside a teardown.
    def report_lane!
      return if reports_own_lines?

      Hash(@settled_loops).each do |run_public_id, settled|
        next if Array(@reported_loops).include?(run_public_id)

        report_loop!(settled.fetch(:row), seconds: settled.fetch(:seconds).round)
      end
    rescue StandardError => error
      warn "the lane's report line could not be printed: #{error.class}: #{error.message.to_s[0, 200]}"
    end

    # The roots the kernel's flat tools mint under a call key — the twin of
    # `AgentRuns::TaskResultEnvelope::FLAT_ROOT` (nexus) and rho's
    # `HostFollower::BRANCH_ROOT`; the SDK exports no key grammar.
    BRANCH_ROOT = /\A(?<call>r\d+t\d+)-(?:model|ask|spawn)-1\z/

    # A message string only — nothing parses it. Mainline tasks in row order, each `task` call followed
    # by its branch's members in braces, and a waiting task with what still holds it: a branch's
    # rounds are `rN` keys too, and flat they read as a mainline runaway.
    def summarize(row)
      tasks = row.fetch("tasks")
      by_call = tasks.group_by { |task| branch_of(task, tasks) }
      Array(by_call[nil]).map do |task|
        members = Array(by_call[task.fetch("key")])
        next describe_task(task) if members.empty?

        "#{describe_task(task)}{#{members.map { |member| describe_task(member) }.join(" ")}}"
      end.join(" ")
    end

    def describe_task(task)
      "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
        "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""}" \
        "#{task["waiting_on"] ? " ⇐ #{task["waiting_on"].join(",")}" : ""}" \
        "#{task.dig("error", "key") ? " !#{task.dig("error", "key")}" : ""})"
    end

    # The call key a branch task hangs from: `after` walked first source
    # first to a key matching BRANCH_ROOT, or nil for a mainline task.
    def branch_of(task, tasks)
      by_key = tasks.to_h { |row| [row.fetch("key"), row] }
      key = task.fetch("key")
      visited = []
      until key.nil? || visited.include?(key)
        match = BRANCH_ROOT.match(key)
        return match[:call] if match

        visited << key
        key = Array(by_key.dig(key, "after")).first
      end
      nil
    end

    # The TAIL only: a host log for a whole journey is thousands of lines
    # and the useful part is what it was doing when it stopped.
    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end

    private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # A loop awaited twice keeps its last row and the sum of its waits.
      def remember_settled(run_public_id, row, seconds)
        @settled_loops ||= {}
        earlier = @settled_loops[run_public_id]
        @settled_loops[run_public_id] = { row: row, seconds: seconds + (earlier ? earlier.fetch(:seconds) : 0) }
        row
      end

      # `#<n>` on the line: the loop's place among the loops the lane
      # awaited, else one past the lines already printed.
      def loop_ordinal(run_public_id)
        index = Hash(@settled_loops).keys.index(run_public_id)
        index ? index + 1 : Array(@reported_loops).size + 1
      end
  end
end
