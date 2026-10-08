require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/session_sign_in_budget"

# THE `user/` RUNG, END TO END. A memory document under `user/` belongs to the controlling Human of
# the TURN's principal — rho's steward when rho's own turn writes it — and it follows that person
# across workspaces: read by their next reply in a workspace rho never touched, through the person's
# own door (`profile/memory`), and by every agent they steward. It never crosses stewards: another
# Human's agent resolves `user/` to ITS steward's scope, where the note simply is not
# (`memory_not_found`, never a scope refusal — the path names no Human). And in a shared
# conversation the rung is the TURN's, not the conversation's: Human B posting into A's conversation
# is shown B's notes, and what B writes there is invisible to A's next turn.
#
# Four turns, one ordered journey, on the mock provider — whose one
# property makes it readable: it echoes its whole joined input, the memory
# block included, so what a turn was SHOWN is on its answer. The echo
# becomes history, so the order of the last half is load-bearing.
class MemoryScopesTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  # Another steward's agent: a device grant confirmed in a browser signed in
  # as `shared_human`, never the fence agent of the dedication lane (that
  # one is confirmed by the rho steward and so is the SAME steward's).
  PROBE_AGENT_IDENTIFIER = "e2e-memory-scopes-probe".freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @human_b = @world.shared_human
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @actor_b = nil
    @home = Dir.mktmpdir("rho-memory-scopes-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    # WHAT THIS LANE LEAVES BEHIND IS ANOTHER LANE'S PROMPT. The world's
    # Humans are shared by every journey and the order is the seed's: an
    # account-wide workspace of the steward's is in every Human's list, and
    # a `user/` note of theirs is rendered into their every later turn —
    # and the mock echoes it. Both are recorded here and taken back in
    # teardown, so the lanes that read the world as fresh still can.
    @created_workspaces = []
    @written_notes = []
    sign_in(@actor, @steward)
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/memory_scopes-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture memory scopes E2E capture: #{error.class}: #{error.message}"
  ensure
    restore_world
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    @actor_b&.close
    @actor&.close
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def test_user_memory_follows_the_person_across_workspaces_and_never_crosses_stewards
    token_a = SecureRandom.hex(4)
    token_b = SecureRandom.hex(4)
    project = connect!
    steward_client = client_for(@steward.member_token)

    # TURN 1: rho's own turn, in rho's dedicated workspace, writes
    # `user/notes.md` through the kernel's tool. The turn's principal is
    # rho's profile, so the note lands in its steward's scope.
    arguments = CGI.escape(JSON.generate({ "path" => "user/notes.md", "content" => "note-#{token_a}" }))
    _conversation, _turn, loop = open_turn("!mock tool_call=memory_write:#{arguments} -- save it", project)
    completed = await_run_status(@workspace_public_id, loop, "completed")
    written = completed.fetch("tasks").find { |task| task["tool_name"] == "memory_write" }
    refute_nil written, "the model never called memory_write: #{summarize(completed)}"
    assert_equal "completed", written.fetch("status"), written.inspect
    assert_includes task_output(@workspace_public_id, loop, written.fetch("key")), "Wrote user/notes.md",
      "the kernel's memory tool wrote the person's note"
    @written_notes += [[@steward.member_token, "user/notes.md"]]

    # TURN 2: the steward, on the member plane, in a SECOND workspace rho
    # never touched — a Human-created conversation has no declaring
    # profile, so its reply is a `direct_reply` and the block is the one
    # reader. The echo carries the block; the person's own door reads the
    # same row.
    other = steward_client.workspaces.create(
      name: "Memory scopes #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    @created_workspaces += [other.public_id]
    chat = open_chat(steward_client, other.public_id)
    remembered = ask(chat, "what do you remember #{SecureRandom.hex(4)}")
    assert_equal @steward.public_id, remembered.answering_user_public_id
    assert_equal "inference", remembered.active_variant.source
    refute_predicate remembered.active_variant, :run_backed?, "the Human's reply reads memory without an agent loop or ask tool"
    assert_includes remembered.text, "## user/notes.md", "the block rendered the person's note in another workspace"
    assert_includes remembered.text, "note-#{token_a}"
    assert_includes steward_client.profile.memory.list.map(&:path), "user/notes.md",
      "the person's own door lists what their agent wrote"
    assert_equal "note-#{token_a}", steward_client.profile.memory.read("user/notes.md").content

    # TURN 3: another steward's agent sees none of it. In an account-wide
    # workspace of A's (B's agent may write there: no dedication, so no
    # fence), a standalone loop with the catalog's memory tools resolves
    # `user/` to B's scope — where A's note is not. `memory_not_found`
    # and an empty listing, never `memory_scope_unavailable`: the grammar
    # names no Human, so there is no scope to refuse.
    shared = steward_client.workspaces.create(
      name: "Memory scopes shared #{SecureRandom.hex(4)}", access_mode: "account_wide",
      idempotency_key: SecureRandom.uuid
    ).workspace
    @created_workspaces += [shared.public_id]
    probe_token = connect_probe_agent_as_b
    script = "memory_read:#{CGI.escape(JSON.generate({ "path" => "user/notes.md" }))}," \
             "memory_ls:#{CGI.escape(JSON.generate({ "path" => "user/" }))}"
    probe_loop = author_and_start(shared.public_id, probe_token, memory_round(script))
    finished = await_run_status(shared.public_id, probe_loop, "completed")
    read = finished.fetch("tasks").find { |task| task["tool_name"] == "memory_read" }
    listed = finished.fetch("tasks").find { |task| task["tool_name"] == "memory_ls" }
    refute_nil read, "B's agent never called memory_read: #{summarize(finished)}"
    refute_nil listed, "B's agent never called memory_ls: #{summarize(finished)}"
    read_output = task_output(shared.public_id, probe_loop, read.fetch("key"))
    ls_output = task_output(shared.public_id, probe_loop, listed.fetch("key"))
    assert_includes read_output, "memory_not_found", "A's note is not in B's scope: #{read_output.inspect}"
    assert_includes ls_output, "No memory documents.", ls_output.inspect
    [read_output, ls_output].each do |output|
      refute_includes output, "memory_scope_unavailable", "a path names no Human; nothing is refused: #{output.inspect}"
      refute_includes output, token_a, "A's note leaked into B's agent's turn: #{output.inspect}"
    end

    # TURN 4: Human B posts into A's conversation in the account-wide
    # workspace (rho's dedicated one is private; B cannot post there). The
    # rung is the TURN's principal's. B FIRST, because every echo becomes
    # history: an A turn ahead of B's first would carry A's token into
    # everything B is shown afterwards.
    chat_a = open_chat(steward_client, shared.public_id)
    chat_b = client_for(@human_b.member_token).workspace(shared.public_id).conversation(chat_a.public_id)

    # (i) B's turn: no notes of B's, and none of A's.
    first_word = "hello-from-b-#{SecureRandom.hex(4)}"
    b_first = ask(chat_b, first_word)
    refute_includes b_first.text, "## user/", "B has no notes, and A's are not B's: #{b_first.text.inspect}"
    refute_includes b_first.text, token_a

    # (ii) A's turn in the same conversation: A's `user/` rendered, in a
    # workspace rho never touched.
    a_first = ask(chat_a, "a-first-#{SecureRandom.hex(4)}")
    a_first_block = memory_block_of(a_first.text, first_word: first_word)
    assert_includes a_first_block, "## user/notes.md", "A's own turn reads A's note: #{a_first.text.inspect}"
    assert_includes a_first_block, "note-#{token_a}"

    # (iii) B writes `user/from-b.md` through the CONVERSATION door — it
    # lands under B's controlling Human, never under the conversation's.
    from_b = chat_b.memory.write("user/from-b.md", "note-#{token_b}", expected_public_id: nil, expected_lock_version: nil)
    assert_equal "user/from-b.md", from_b.path
    @written_notes += [[@human_b.member_token, "user/from-b.md"]]

    # (iv) A's next turn: A's note, and NOT B's.
    a_second = ask(chat_a, "a-second-#{SecureRandom.hex(4)}")
    assert_includes a_second.text, "note-#{token_a}"
    refute_includes a_second.text, token_b, "B's write reached A's next turn: #{a_second.text.inspect}"

    # (v) B's next turn: B's note, and NOT A's — the positive control that
    # (iii) wrote somewhere the block reads. History now carries A's
    # echoes, token and all, so the negative is on the BLOCK the turn was
    # shown: the head of the echo, before the conversation's first word.
    b_second = ask(chat_b, "b-second-#{SecureRandom.hex(4)}")
    b_second_block = memory_block_of(b_second.text, first_word: first_word)
    assert_includes b_second_block, "## user/from-b.md", "B's turn reads B's note: #{b_second.text.inspect}"
    assert_includes b_second_block, "note-#{token_b}"
    refute_includes b_second_block, token_a, "A's note was rendered for B's turn: #{b_second_block.inspect}"

    # Each person's own door holds exactly their own note.
    assert_equal ["user/notes.md"], steward_client.profile.memory.list.map(&:path)
    assert_equal ["user/from-b.md"], client_for(@human_b.member_token).profile.memory.list.map(&:path)
  end

  private

    # The daemon connected and adopted, the dev lane open, the hosts up
    # (the memory verbs run in the jobs host's MemoryJob; materialization
    # is DrainJob's) — before the first `rho do`.
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

    # `rho do`, and the three ids its output contract prints.
    def open_turn(prompt, project)
      output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      ids = %w[conversation turn run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
      refute_includes ids, nil, "rho do printed fewer than three ids:\n#{output}"
      ids
    end

    def client_for(token) = CybrosAgent::Client.new(base_url: @base_url, credential: token)

    # The world as this lane found it: each person's `user/` note deleted
    # through their own door, each workspace the steward created
    # tombstoned (delete is accepted from `active`; the tombstone leaves
    # every list at commit). Best effort — a lane that failed midway may
    # have made only some of these, and a miss is reported, never raised.
    def restore_world
      (@written_notes || []).each do |token, path|
        memory = client_for(token).profile.memory
        document = memory.read(path)
        memory.delete(path, expected_public_id: document.public_id, expected_lock_version: document.lock_version)
      rescue StandardError => error
        warn "Could not delete #{path} after the memory scopes lane: #{error.class}: #{error.message}"
      end
      (@created_workspaces || []).each do |public_id|
        client = client_for(@steward.member_token)
        client.workspace(public_id).delete(lock_version: client.workspaces.fetch(public_id).lock_version)
      rescue StandardError => error
        warn "Could not delete workspace #{public_id} after the memory scopes lane: #{error.class}: #{error.message}"
      end
    end

    def open_chat(client, workspace_public_id)
      conversations = client.workspace(workspace_public_id).conversations
      created = conversations.create(title: "Memory scopes", idempotency_key: SecureRandom.uuid)
      conversations.conversation(created.public_id)
    end

    # One `direct_reply` on the conversation, as whoever `chat` speaks for,
    # and its settled reply: the first completed `direct_reply` past the
    # positions already on the timeline — the conversation is shared, so
    # "the last turn" may be somebody else's.
    def ask(chat, text)
      after = chat.turns.list.items.map(&:position).max || -1
      chat.inputs.create(kind: "direct_reply", model: MODEL, text: text, idempotency_key: SecureRandom.uuid)
      await("no reply settled for #{text.inspect}", every: TURN_POLL) do
        newer = chat.turns.list.items.select { |turn| turn.position > after && turn.kind == "direct_reply" }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply to #{text.inspect} failed: #{failed.to_h.inspect}" if failed
        newer.find { |turn| turn.status == "completed" }
      end
    end

    # THE BLOCK A TURN WAS SHOWN. Assembly leads with the slots — none registered in this lane —
    # then memory, then history, then the prompt, and the mock echoes the joined input in that order
    # — so the echo's head, up to the conversation's first word, is this turn's block and nothing
    # older.
    def memory_block_of(text, first_word:)
      index = text.index(first_word)
      refute_nil index, "the echo never reached the history: #{text.inspect}"
      text[0, index]
    end

    # ---- another steward's agent ----

    # A device grant no daemon owns, confirmed in a SECOND browser signed in
    # as Human B: the agent it mints is B's, and its `user/` is B's. One
    # sign-in unit and one device-authorization unit.
    def connect_probe_agent_as_b
      @actor_b = E2E::BrowserActor.new(@base_url)
      sign_in(@actor_b, @human_b)
      flow = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = flow.request_authorization(
        agent_identifier: PROBE_AGENT_IDENTIFIER,
        agent_display_name: "E2E memory scopes probe",
        executor_display_name: "E2E memory scopes probe app"
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

    # THE DECLARATIONS COME FROM THE CATALOG (workspace_dedication_test):
    # a kernel tool declared with any other bytes is `kernel_tool_redefined`.
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

    def loop_row(workspace_public_id, loop)
      document = agent_api(:get, loop_path(workspace_public_id, loop))
      document.fetch("run") { flunk "the loop read was refused: #{document.inspect}" }
    end

    def task_output(workspace_public_id, loop, task_key)
      agent_api(:get, "#{loop_path(workspace_public_id, loop)}/tasks/#{task_key}").dig("task", "output").to_s
    end

    def await_run_status(workspace_public_id, loop, status)
      await("the loop never reached #{status}", every: LOOP_POLL) do
        row = loop_row(workspace_public_id, loop)
        row if row["status"] == status
      end
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
    end

    # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
    # routes), so every poll is paced. Three identities read here — the
    # steward, Human B and B's agent — each under its own budget.
    LOOP_POLL = 1
    TURN_POLL = 1
    AWAIT_SECONDS = 90

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

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
