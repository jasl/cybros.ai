require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/session_sign_in_budget"

# THE TOOLS-PROVIDER OVERRIDE, END TO END. A workspace opts its `nexus.memory` family into a tools
# provider (`PUT …/tool_provider_overrides`); from then on the six memory verbs ride the inbox to
# THAT provider with the kernel's `scope` stamp, the kernel's assembly block goes silent for the
# workspace, the member memory door refuses `memory_overridden`, and the kernel's own rows wait
# untouched until the override clears. The provider is the harness's sample (`E2E::MemoryTools`, an
# in-memory store keyed by the row's scope), granted ACCOUNT-WIDE by the founding owner so another
# Human's agent can reach it too — which is what proves the scope stamp: two workspaces'
# `workspace/notes.md` are two documents at the provider, and steward A's `user/` write is invisible
# to Human B's agent.
#
# Seven loops, one ordered journey, one conversation of rho's: the kernel
# writes first (the pre-image the clearing turn restores), the provider
# serves turns 2–4 as the named claimant, a KILLED AND REVOKED provider
# fails a read `tool_not_served` with no kernel fallback, and `{}` brings
# the kernel's row and block back.
class ProviderOverrideTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  NAMESPACE = "nexus.memory".freeze
  # The provider's own registration key (one live address per (manager, identifier) across both
  # kinds), under the OWNER — no sibling lane pairs it, so its scope is this lane's choice every
  # run.
  PROVIDER_IDENTIFIER = "e2e-memory-provider".freeze
  PROVIDER_DISPLAY_NAME = "E2E memory provider".freeze
  # Human B's agent, as the memory-scopes lane mints it: a device grant
  # confirmed in a browser signed in as `shared_human`.
  PROBE_AGENT_IDENTIFIER = "e2e-provider-override-probe".freeze
  NOTE = "workspace/notes.md".freeze
  # The mock echoes its whole input, and each echo becomes history. The
  # setup and intermediate turns speak one word to limit that growth. Memory assertions
  # read the first round's sealed request; later rounds may compact.
  QUIET = "reply=#{CGI.escape("noted")}".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    # The lane's OWN steward (`ActorProvisioning#override_steward`): rho's
    # dedicated workspace is a row per steward, so the override this lane
    # PUTs on W1 is read by no other lane's rho — the shared steward's
    # files (group 3's `rho_attachments` among them) address a different row.
    @steward = @world.override_steward
    @human_b = @world.shared_human
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @actor_b = nil
    @client = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    @home = Dir.mktmpdir("rho-provider-override-e2e")
    @provider_home = Dir.mktmpdir("e2e-memory-provider-process")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @provider = nil
    # What this lane leaves behind is the world's residue (the memory
    # scopes lane's rule): the private steward's dedicated workspace is the
    # same row for every test of THIS file, so its override is cleared and
    # its kernel note deleted in teardown; the workspaces this lane creates
    # are tombstoned.
    @overridden_workspaces = []
    @created_workspaces = []
    @written_notes = []
    sign_in(@actor, @steward)
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      warn_log(@provider&.log_path, "provider process log")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/provider_override-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture provider override E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the provider process") { @provider&.stop }
    revoke_provider_quietly
    restore_world
    stop_quietly("the rho daemon") { @daemon&.stop }
    @actor_b&.close
    @actor&.close
    [@home, @provider_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_a_workspace_routes_memory_to_a_provider_keyed_by_scope_and_the_kernel_returns_when_cleared
    t = SecureRandom.hex(4)
    project = connect!
    steward = client_for(@steward.member_token)
    w1 = @workspace_public_id
    @provider = grant_provider_as_owner
    assert_equal "tool_provider", @provider.announced_kind, "the address carries the kind the grant named"
    assert_equal E2E::MemoryTools.names.sort, @provider.announced.sort

    # TURN 0: the kernel's own row, before any override — the pre-image
    # the clearing turn restores. Addressed to nobody, claimed by nobody.
    opener = "opener-#{t}"
    conversation, _turn, loop_0 = open_turn("!mock #{QUIET} tool_call=#{call("memory_write", "path" => NOTE, "content" => "kernel-#{t}")} -- #{opener}", project)
    written = task_of(completed!(await_loop_settled(w1, loop_0)), "memory_write")
    assert_equal "completed", written.fetch("status"), written.inspect
    assert_includes written.fetch("output").to_s, "Wrote #{NOTE}", "the kernel wrote the pre-image"
    refute written.key?("addressed_to"), "a kernel row is addressed to nobody: #{written.inspect}"
    refute written.key?("claimed_by"), "and claimed by nobody"
    @written_notes += [[w1, conversation, NOTE]]

    # TURN 1: the steward opts rho's dedicated workspace in. The read names
    # the provider and its scope; the CAS moved; a stale repeat is refused;
    # the conversation memory door now refuses, the person's own does not.
    seen = steward.workspaces.fetch(w1)
    set = steward.workspace(w1).set_tool_provider_overrides(
      overrides: { NAMESPACE => @provider.executor_public_id }, lock_version: seen.lock_version
    )
    @overridden_workspaces += [w1]
    entry = set.tool_provider_overrides.fetch(NAMESPACE)
    assert_equal @provider.executor_public_id, entry.provider_public_id
    assert_equal PROVIDER_DISPLAY_NAME, entry.display_name
    assert_equal "account_wide", entry.assignment_scope, "granted by the owner, so every member reaches it"
    assert_equal seen.lock_version + 1, set.lock_version
    stale = assert_raises(CybrosAgent::Api::Conflict) do
      steward.workspace(w1).set_tool_provider_overrides(
        overrides: { NAMESPACE => @provider.executor_public_id }, lock_version: seen.lock_version
      )
    end
    assert_equal "stale_object", stale.code
    chat = steward.workspace(w1).conversation(conversation)
    overridden = assert_raises(CybrosAgent::Api::Conflict) { chat.memory.list }
    assert_equal "memory_overridden", overridden.code
    assert_includes overridden.message, PROVIDER_DISPLAY_NAME, "the refusal names the provider"
    steward.profile.memory.list # the person's own door is not a workspace's

    # TURN 2: the same write rides the inbox to the provider — the row
    # names it as addressee and claimant, its answer is the kernel's
    # sentence — while the KERNEL'S ROW STILL EXISTS and the block shows
    # the model nothing of it.
    # ONE answer in the history so far (turn 0's), so the script is padded
    # to reach its call (the handoff lane's rule: the mock counts answers
    # across the whole input, and every tool row — failed ones too —
    # renders one).
    loop_1 = say(conversation, "!mock #{QUIET} tool_call=#{padded(1, call("memory_write", "path" => NOTE, "content" => "provider-#{t}"))} -- overwrite it",
      known: [loop_0])
    written = task_of(completed!(await_loop_settled(w1, loop_1)), "memory_write")
    assert_equal "completed", written.fetch("status"), written.inspect
    assert_provider_row(written)
    assert_includes written.fetch("output").to_s, "Wrote #{NOTE}", "the provider speaks the kernel's sentence"
    assert_includes @provider.claimed_keys, written.fetch("key"), "the provider's own log says it took the row"
    block = memory_block_of(loop_1)
    refute_includes block, "## #{NOTE}", "the kernel block is silent under the override: #{block.inspect}"
    refute_includes block, "kernel-#{t}"

    # TURN 3: a `user/` write and a read of the note, both the provider's;
    # the read answers what the PROVIDER holds, never the kernel's row.
    script = padded(2, call("memory_write", "path" => "user/notes.md", "content" => "user-#{t}"),
      call("memory_read", "path" => NOTE))
    loop_2 = say(conversation, "!mock #{QUIET} tool_call=#{script} -- read it back", known: [loop_0, loop_1])
    settled = completed!(await_loop_settled(w1, loop_2))
    %w[memory_write memory_read].each { |name| assert_provider_row(task_of(settled, name)) }
    read = task_of(settled, "memory_read")
    assert_equal "provider-#{t}", read.fetch("output").to_s.strip, "the provider's document, not the kernel's"

    # TURN 4: A SECOND WORKSPACE AND HUMAN B'S AGENT. The account-wide
    # provider darkens nobody, so an account-wide workspace admits it; B's
    # agent writes the same path there and reads A's `user/` — the
    # provider keys by the stamp, so W2's note is a second document and
    # A's `user/notes.md` is simply not in B's scope.
    w2 = steward.workspaces.create(
      name: "Provider override #{SecureRandom.hex(4)}", access_mode: "account_wide",
      idempotency_key: SecureRandom.uuid
    ).workspace
    @created_workspaces += [w2.public_id]
    set_w2 = steward.workspace(w2.public_id).set_tool_provider_overrides(
      overrides: { NAMESPACE => @provider.executor_public_id }, lock_version: w2.lock_version
    )
    @overridden_workspaces += [w2.public_id]
    assert_equal @provider.executor_public_id, set_w2.tool_provider_overrides.fetch(NAMESPACE).provider_public_id
    token_b = connect_probe_agent_as_b
    b_script = "#{call("memory_write", "path" => NOTE, "content" => "b-#{t}")}," \
               "#{call("memory_read", "path" => "user/notes.md")},#{call("memory_ls", {})}"
    loop_b = author_and_start(w2.public_id, token_b, memory_round(b_script))
    finished = completed!(await_loop_settled(w2.public_id, loop_b, token: token_b))
    b_write = task_of(finished, "memory_write")
    b_read = task_of(finished, "memory_read")
    b_ls = task_of(finished, "memory_ls")
    assert_provider_row(b_write)
    assert_includes b_write.fetch("output").to_s, "Wrote #{NOTE}"
    assert_includes b_read.fetch("output").to_s, "memory_not_found", "A's user/ note is not in B's scope: #{b_read.inspect}"
    refute_includes b_read.fetch("output").to_s, "user-#{t}"
    listed = b_ls.fetch("output").to_s
    assert_equal [NOTE], listed.lines.map { |line| line.split("  ").first }, "B's own document alone: #{listed.inspect}"
    refute_includes listed, "user/", "never A's user/ note"
    refute_includes listed, "provider-#{t}"
    loop_3 = say(conversation, "!mock #{QUIET} tool_call=#{padded(4, call("memory_read", "path" => NOTE))} -- still there?",
      known: [loop_0, loop_1, loop_2])
    read = task_of(completed!(await_loop_settled(w1, loop_3)), "memory_read")
    assert_provider_row(read)
    assert_equal "provider-#{t}", read.fetch("output").to_s.strip, "two workspaces, two documents at one provider"

    # TURN 5: GONE. A killed process leaves a live registration (its rows
    # would park until the sweep), so the lane REVOKES it as an operator
    # would; the next read fails at start `tool_not_served` naming the
    # provider — no kernel fallback, the kernel's row is not read.
    @provider.kill!
    E2E.operator.revoke_executor!(@provider.executor_public_id)
    loop_4 = say(conversation, "!mock #{QUIET} tool_call=#{padded(5, call("memory_read", "path" => NOTE))} -- anyone there?",
      known: [loop_0, loop_1, loop_2, loop_3])
    # The refusal is data the model reads on its next round (absorbed),
    # so the loop still completes.
    read = task_of(completed!(await_loop_settled(w1, loop_4)), "memory_read")
    assert_equal "failed", read.fetch("status"), read.inspect
    assert_equal "tool_not_served", read.dig("error", "key"), read.inspect
    assert_includes read.dig("error", "detail").to_s, @provider.executor_public_id, "the detail names the provider"
    refute_includes read.fetch("output").to_s, "kernel-#{t}", "no kernel fallback"
    refute read.key?("claimed_by")
    still = steward.workspaces.fetch(w1).tool_provider_overrides.fetch(NAMESPACE)
    assert_equal PROVIDER_DISPLAY_NAME, still.display_name, "revoked, not reaped: the read still names it"

    # TURN 6: CLEARED. `{}` restores the kernel: the read is the kernel's
    # own row with the pre-image, the block is back, and the door answers.
    cleared = steward.workspace(w1).set_tool_provider_overrides(
      overrides: {}, lock_version: steward.workspaces.fetch(w1).lock_version
    )
    assert_equal({}, cleared.tool_provider_overrides)
    @overridden_workspaces -= [w1]
    # Six answers behind it now: the failed read of turn 5 rendered one too.
    loop_5 = say(conversation, "!mock tool_call=#{padded(6, call("memory_read", "path" => NOTE))} -- what do you remember",
      known: [loop_0, loop_1, loop_2, loop_3, loop_4])
    read = task_of(completed!(await_loop_settled(w1, loop_5)), "memory_read")
    assert_equal "completed", read.fetch("status"), read.inspect
    assert_equal "kernel-#{t}", read.fetch("output").to_s.strip, "the kernel's row waited untouched"
    refute read.key?("addressed_to"), "the kernel's own row again: #{read.inspect}"
    refute read.key?("claimed_by")
    block = memory_block_of(loop_5)
    assert_includes block, "## #{NOTE}", "the block is back: #{block.inspect}"
    assert_includes block, "kernel-#{t}"
    assert_includes chat.memory.list.map(&:path), NOTE, "the conversation door answers again"
  end

  private

    # ---- the world ----

    # The daemon connected and adopted, the dev lane open, the hosts up —
    # before the first `rho do`. rho's dedicated workspace is W1.
    def connect!
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      @workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")
      E2E.enable_dev_lane!
      E2E.hosts.start
      project = File.join(@home, "project")
      FileUtils.mkdir_p(project)
      project
    end

    # THE OWNER'S GRANT: a provider a plain member connects is private to the profiles they manage,
    # and Human B's agent could never reach it — so the founding owner connects this one
    # ACCOUNT-WIDE in the shared owner session. The page offers the selector to an owner; a
    # registration a sibling run already paired inherits its scope, and only `account_wide` serves
    # this lane.
    def grant_provider_as_owner
      E2E::DeviceAuthorizationBudget.consume
      authorization = @client.request_runner_authorization(
        registration_identifier: PROVIDER_IDENTIFIER, runner_display_name: PROVIDER_DISPLAY_NAME,
        executor_kind: "tool_provider"
      )
      assert_equal :runner, authorization.branch, "the branch is the credential's shape for both kinds"
      @world.with_owner_browser do |owner|
        E2E::RunnerGrant.visit_connection(actor: owner, authorization: authorization)
        offer = E2E::RunnerGrant.scope_offer(owner)
        assert_includes %i[selector account_wide], offer,
          "an owner may make the provider account-wide, and this lane needs it so: #{offer.inspect}"
        E2E::RunnerGrant.connect_in_browser(actor: owner, authorization: authorization,
          account_wide: offer == :selector, existing_runner_scope: (offer if offer == :account_wide))
      end
      credentials = @client.await_credentials(authorization)
      assert_nil credentials.access_token, "a machine is a delivery address, never a member principal"
      E2E::ExecutorProcess.new(base_url: @base_url, home: @provider_home,
        credential: credentials.executor_access_token, kind: :tool_provider, tools: E2E::MemoryTools.names).start
    end

    # Idempotent, and best effort: a lane that failed before the grant has
    # nothing to revoke, and `revoke` is a no-op on a revoked row.
    def revoke_provider_quietly
      public_id = @provider&.executor_public_id
      return if public_id.nil?

      E2E.operator.revoke_executor!(public_id)
    rescue StandardError => error
      warn "Could not revoke the provider after the override lane: #{error.class}: #{error.message}"
    end

    # The world as this lane found it: every override cleared (so the
    # conversation door answers), the kernel note deleted through that
    # door, each created workspace tombstoned. A miss is reported, never raised.
    def restore_world
      steward = client_for(@steward.member_token)
      (@overridden_workspaces || []).each do |public_id|
        steward.workspace(public_id).set_tool_provider_overrides(
          overrides: {}, lock_version: steward.workspaces.fetch(public_id).lock_version
        )
      rescue StandardError => error
        warn "Could not clear the override on #{public_id} after the override lane: #{error.class}: #{error.message}"
      end
      (@written_notes || []).each do |workspace, conversation, path|
        memory = steward.workspace(workspace).conversation(conversation).memory
        document = memory.read(path)
        memory.delete(path, expected_public_id: document.public_id, expected_lock_version: document.lock_version)
      rescue StandardError => error
        warn "Could not delete #{path} after the override lane: #{error.class}: #{error.message}"
      end
      (@created_workspaces || []).each do |public_id|
        steward.workspace(public_id).delete(lock_version: steward.workspaces.fetch(public_id).lock_version)
      rescue StandardError => error
        warn "Could not delete workspace #{public_id} after the override lane: #{error.class}: #{error.message}"
      end
    end

    def client_for(token) = CybrosAgent::Client.new(base_url: @base_url, credential: token)

    # ---- rho's verbs ----

    # `rho do`, and the three ids its output contract prints.
    def open_turn(prompt, project)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    # `rho say` on the conversation, and the loop backing the turn it
    # opened — the feed's `turn_status` for a direct reply naming a loop
    # this lane has not seen. Compaction summaries have their own loops.
    def say(conversation, text, known:)
      said, status = @daemon.cli("say", conversation, text)
      assert_predicate status, :success?, "rho say failed:\n#{said}"
      await_next_turn(conversation, known: known)
    end

    def call(name, arguments) = "#{name}:#{CGI.escape(JSON.generate(arguments))}"

    # THE MOCK'S ONLY CLOCK is the count of tool answers in its whole
    # input (`MockLLM::App#answers_in`), history included, so a script on
    # a conversation that already holds `answered` results is padded to
    # that index — the padding entries are never reached — and the calls
    # this turn means come after them, in order.
    def padded(answered, *calls) = ([calls.first] * answered + calls).join(",")

    # ---- what the transcript says ----

    # A row the PROVIDER answered: addressed to it by the override (its
    # role and its id — never a bare pool role), claimed by it.
    def assert_provider_row(task)
      assert_equal({ "role" => "tool_provider", "executor_public_id" => @provider.executor_public_id },
        task.fetch("addressed_to").slice("role", "executor_public_id"), "the override addresses the named provider: #{task.inspect}")
      assert_equal({ "executor_public_id" => @provider.executor_public_id }, task.fetch("claimed_by"),
        "the provider is named as claimant: #{task.inspect}")
    end

    # The task detail of the named verb — `addressed_to`, `claimed_by`,
    # `output`, `error` — read off the member plane.
    def task_of(row, tool_name)
      task = row.fetch("tasks").find { |candidate| candidate["tool_name"] == tool_name }
      refute_nil task, "the model never called #{tool_name}: #{summarize(row)}"
      detail = agent_api(:get, "#{row.fetch("path")}/tasks/#{task.fetch("key")}", token: row.fetch("token")).fetch("task")
      detail.merge("output" => detail["output"].to_s)
    end

    # The first round's request preserves the assembly before later rounds
    # compact. Memory is its own user text part; older mock echoes are
    # assistant parts and cannot stand in for the current memory block.
    def memory_block_of(run_public_id)
      request = client_for(@steward.member_token).workspace(@workspace_public_id)
        .runs.run(run_public_id).tasks_context("r1").request
      request.entries.select { |entry| entry["role"] == "user" }
        .flat_map { |entry| entry.fetch("parts") }
        .filter_map { |part| part["text"] }
        .find { |text| text.start_with?("Durable memory for this conversation,") } || ""
    end

    # ---- another steward's agent ----

    # A device grant no daemon owns, confirmed in a SECOND browser signed in
    # as Human B: the agent it mints is B's, and its `user/` is B's.
    def connect_probe_agent_as_b
      @actor_b = E2E::BrowserActor.new(@base_url)
      sign_in(@actor_b, @human_b)
      flow = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = flow.request_authorization(
        agent_identifier: PROBE_AGENT_IDENTIFIER,
        agent_display_name: "E2E provider override probe",
        executor_display_name: "E2E provider override probe app"
      )
      E2E::Ceremony.confirm(actor: @actor_b, status: nil, started: {
        "verification_uri_complete" => authorization.verification_uri_complete,
        "user_code" => authorization.user_code,
        "branch" => "agent",
      })
      flow.await_credentials(authorization).access_token
    end

    # A standalone loop authored and started over the member plane as the
    # probe agent: one model step declaring the catalog's memory tools.
    def author_and_start(workspace_public_id, token, step)
      authored = agent_api(:post, "/agent_api/v1/workspaces/#{workspace_public_id}/runs",
        body: { run: { steps: [step], approval_mode: "bypass" } }, token: token)
      public_id = authored.dig("run", "public_id")
      refute_nil public_id, "nexus refused the probe agent's loop: #{authored.inspect}"
      started = agent_api(:post, "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{public_id}/start",
        token: token)
      assert_equal "running", started.dig("run", "status"), "the probe loop never started: #{started.inspect}"
      public_id
    end

    # The declarations come from the catalog: a kernel tool declared with
    # any other bytes is `kernel_tool_redefined`.
    def memory_round(script)
      { model: {
        key: "m1", model: { model: MODEL },
        tools: kernel_memory_tools,
        prompt: "!mock tool_call=#{script} -- look for it",
      } }
    end

    def kernel_memory_tools
      agent_api(:get, "/agent_api/v1/tools")
        .fetch("tools")
        .select { |tool| tool.fetch("canonical_name").start_with?("nexus.memory.") }
        .map { |tool| tool.fetch("definition") }
    end

    # ---- reads on the member plane ----

    def loop_path(workspace_public_id, loop) = "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop}"

    # A loop at rest — completed, or failed/blocked when a row failed at
    # start — with the path and bearer its tasks are read under.
    SETTLED = %w[completed needs_attention canceled].freeze

    def await_loop_settled(workspace_public_id, loop, token: @steward.member_token)
      path = loop_path(workspace_public_id, loop)
      await("the loop #{loop} never settled", every: LOOP_POLL) do
        document = agent_api(:get, path, token: token)
        row = document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
        row.merge("path" => path, "token" => token) if SETTLED.include?(row["status"])
      end
    end

    def await_next_turn(conversation, known:)
      await("the next turn on #{conversation} never started", every: TURN_POLL) do
        feed(conversation).filter_map do |item|
          if item["type"] == "turn_status" && item.dig("payload", "turn_kind") == "direct_reply"
            item.dig("payload", "run_public_id")
          end
        end.find { |loop| !known.include?(loop) }
      end
    end

    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api(:get, "/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    # A loop that COMPLETED, or the tasks and their errors in the message.
    def completed!(row)
      errors = row.fetch("tasks").filter_map { |task| task["error"] && "#{task.fetch("key")}=#{task["error"].inspect}" }
      assert_equal "completed", row.fetch("status"),
        "the loop did not complete (#{row["failure_reason"].inspect}): #{summarize(row)} #{errors.join(" ")}"
      row
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    # The member plane is rate-limited per caller, so every poll is paced.
    LOOP_POLL = 1
    TURN_POLL = 1
    AWAIT_SECONDS = 120

    def await(message, every:)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = begin
          yield
        rescue CybrosAgent::Api::RateLimited => throttle
          flunk "the journey tripped the API's own rate limit (Retry-After #{throttle.retry_after}s)"
        end
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    # The member plane as the steward unless another bearer is named. UTF-8
    # by name: the test process inherits the machine's empty locale.
    def agent_api(verb, path, body: nil, token: @steward.member_token)
      uri = URI.join(@base_url, path)
      request = verb == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid if verb == :post
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    def sign_in(actor, human)
      actor.visit("/session/new")
      actor.page.fill_in "Email", with: human.email
      actor.page.fill_in "Password", with: human.password
      E2E::SessionSignInBudget.consume
      actor.page.click_button "Sign in"
      assert actor.page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
