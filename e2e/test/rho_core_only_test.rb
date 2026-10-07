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

# THE CORE ALONE: a daemon whose settings add no extension and whose shipped default is reduced to
# the runner's Coding set — no Ops, Until, Files, Environment, ConsoleLink, Processes, Guard,
# Conventions — still opens a conversation through its own door and the turn completes on Coding's
# tools. The daemon's `POST /conversations` opens a CONVERSATION and says the prompt on it (the
# core's door — `rho run` needs Ops's follow route, which this synthetic world lacks, and `do` is
# rho-dev's); the kernel materializes the turn into a loop backed by tools assembled from the boot
# declaration (Coding's nine plus the kernel's); the mock model calls one; rho's runner answers it on
# this machine; the turn completes. The daemon never touches the loop door for its own turn —
# asserted over the dispatch log the prelude writes. The shipped binary on this product home lists
# the management verbs and `run`, and no extension section.
class RhoCoreOnlyTest < Minitest::Test
  PRELUDE = File.expand_path("../support/core_only_prelude.rb", __dir__)
  # Coding's runner tools; kernel declarations are listed separately below.
  CORE_TOOLS = %w[bash edit file_import file_publish find grep ls read write].freeze
  # The kernel tools rho declares by default: the memory family, ask, delegate_task, the four conversation
  # verbs, history reads, discovery/invocation and the `skill` load — declared whether or not this checkout holds a skill;
  # the kernel omits it at the wire alone while the catalog is empty.
  KERNEL_TOOLS = %w[ask cancel memory_delete memory_edit memory_grep memory_ls memory_read memory_write send
                    session_read session_search skill spawn status delegate_task tool_search tool_call runners_list].freeze
  EXTENSION_VERBS = %w[followers runs watch result follow graph attach processes env runner console do say stop].freeze

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-core-only-e2e")
    # The temporary settings name no extension; the prelude, loaded through
    # RUBYOPT into the daemon and the CLI alike, shrinks the shipped default.
    File.write(File.join(@home, "settings.json"),
      JSON.generate({ "settings_version" => 1, "plugins" => %w[rho.webui rho.ingress_telegram rho.codemode].to_h { |id| [id, { "enabled" => false }] } }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, env: { "RUBYOPT" => "-r#{PRELUDE}" })
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      warn_log(File.join(@home, "dispatch.log"), "rho dispatch log") if @home
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/rho_core_only-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho core-only E2E capture: #{error.class}: #{error.message}"
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, output
    end
    @actor&.close
    [@home, @project].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_the_core_alone_opens_a_conversation_and_runs_a_coding_turn
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    workspace_public_id = await_workspace_state("adopted").dig("workspace", "public_id")

    # The extensions are really gone: their routes answer 404 (a POST, since
    # an unclaimed GET lands on the page) and their verbs are not installed.
    # The standalone-loop author is Ops's now.
    assert_equal "not_found", @daemon.control(:post, "/followers/attach", body: {}).dig("error", "code"),
      "POST /followers/attach is Ops's; a core-only daemon has no such route"
    assert_equal "not_found", @daemon.control(:post, "/runs", body: {}).dig("error", "code"),
      "POST /runs is Ops's standalone author; the core opens conversations"
    assert_equal "not_found", @daemon.control(:post, "/environment", body: {}).dig("error", "code"),
      "POST /environment is Environment's; a core-only daemon has no such route"
    helped, status = @daemon.cli("help")
    assert_predicate status, :success?, helped
    refute_match(/^Extension /, helped, "no extension registered a verb:\n#{helped}")
    EXTENSION_VERBS.each { |verb| refute_match(/^  rho #{verb}\b/, helped, helped) }
    assert_match(/^  rho run \[PROMPT\]/, helped, "the one conversation verb is the core's own:\n#{helped}")

    E2E.enable_dev_lane!
    E2E.hosts.start

    # Beside the home, never under it: `$RHO_HOME` is a protected root and
    # the Guard's floor resolves a `write` path before judging it (the
    # `rho_conversation` lane's note).
    project = @project = Dir.mktmpdir("rho-core-only-project")
    note = File.join(project, "note.txt")
    arguments = CGI.escape(JSON.generate({ "path" => note, "content" => "hello from the core\n" }))
    # THE CORE'S OWN DOOR: the 201 document's three ids (the output
    # contract `rho run` prints and the paid lanes parse is `rho_run`'s
    # pin; this lane proves the door and the declaration).
    answer = @daemon.control(:post, "/conversations", body: {
      "prompt" => "!mock tool_call=write tool_args=#{arguments} -- write the note and say so",
      "model" => "dev/mock-text", "working_directory" => project,
    })
    conversation_id = answer.dig("conversation", "public_id")
    turn_id = answer.dig("turn", "public_id")
    loop_id = answer.dig("run", "public_id")
    refute_nil conversation_id, "the core's door refused: #{answer.inspect}"
    refute_nil turn_id, answer.inspect
    refute_nil loop_id, answer.inspect

    # The BACKING loop's trace — loop-grain, valid on a loop-backed loop.
    completed = await_loop_completion do
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}")
    end
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{completed.fetch("tasks").inspect}"
    assert_equal "write", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    assert_equal "hello from the core\n", File.read(note, encoding: Encoding::UTF_8),
      "the core's runner wrote the file the model asked for"

    # The public accepted model task carries exactly Coding's tools and the kernel's. The
    # dispatch log separately proves the turn was authored through the conversation door: no loop
    # create, start or input for it. The runner's inbox reads and its claim/commit lines ride the
    # EXECUTOR plane (`GET /agent_api/v1/executor/inbox`, `POST
    # …/executor/inbox/{loop}/{key}/claim|commit`) and are expected; no member-plane runner door
    # exists to be called.
    dispatched = File.read(File.join(@home, "dispatch.log"), encoding: Encoding::UTF_8).lines.map(&:chomp)
    assert dispatched.grep(%r{\AGET /agent_api/v1/executor/inbox\z}).any?,
      "the runner never listed its inbox on the executor plane:\n#{dispatched.join("\n")}"
    assert_empty dispatched.grep(%r{agent_run_task_inbox|/tasks/[^/]+/(claim|result)\z}),
      "a member-plane runner door was called"
    declaration = dispatched.find { |line| line.start_with?("PUT /agent_api/v1/profile/configuration") }
    refute_nil declaration, "the boot declaration never reached the kernel:\n#{dispatched.join("\n")}"
    assert_empty dispatched.grep(%r{\A(?:PUT|DELETE) /agent_api/v1/profile/prompt_documents/}),
      "the Profile's configuration and prompts must be written in one declaration"
    # EACH ADDRESS announced what it serves BEFORE the profile was declared: a core-only rho is FULL
    # mode — Coding is a runner tool — so one page paired both addresses and both announced (the
    # runner's Coding set, the agent's nothing); the kernel addresses the `write` above by the
    # announcement, and a runner that declared first could meet `tool_not_served`.
    announcements = dispatched.each_index.select { |i| dispatched[i].start_with?("PUT /agent_api/v1/executor/announcement") }
    assert_equal 2, announcements.length,
      "one announcement per address, two addresses:\n#{dispatched.join("\n")}"
    announcements.each do |index|
      assert_operator index, :<, dispatched.index(declaration),
        "every announcement must precede the declaration:\n#{dispatched.join("\n")}"
    end
    model_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "model_task" }
    definitions = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{model_task.fetch("key")}")
      .fetch("task").fetch("tool_definitions")
    names = definitions.map { |entry| entry.fetch("function").fetch("name") }.sort
    runner_skills, ordinary_tools = names.partition { |name| name.start_with?("skill__") }
    assert_equal 1, runner_skills.length, "the Runner's skill loader has its own callable name beside the kernel skill: #{names}"
    assert_equal (CORE_TOOLS + KERNEL_TOOLS).sort, ordinary_tools,
      "the accepted model task carries Coding's tools and the kernel's, nothing else: #{names}"
    loops_path = %r{\APOST /agent_api/v1/workspaces/[^/]+/runs}
    assert_empty dispatched.grep(%r{#{loops_path}\z}), "the daemon authored a loop for its own turn"
    assert_empty dispatched.grep(%r{#{loops_path}/[^/]+/start\z}), "the daemon started a loop for its own turn"
    assert_empty dispatched.grep(%r{#{loops_path}/[^/]+/inputs\z}), "the daemon spoke through the loop door"
    conversations_path = %r{\APOST /agent_api/v1/workspaces/[^/]+/conversations}
    assert dispatched.grep(%r{#{conversations_path}\z}).any?, "no conversation was opened:\n#{dispatched.join("\n")}"
    assert dispatched.grep(%r{#{conversations_path}/#{Regexp.escape(conversation_id)}/inputs\z}).any?,
      "the prompt never rode a conversation input"
    assert dispatched.grep(%r{\AGET /agent_api/v1/workspaces/[^/]+/conversations/#{Regexp.escape(conversation_id)}/events}).any?,
      "the follower never read the conversation's feed"

    # The core's own read of the loop it follows, through the shipped verb.
    listed, status = @daemon.cli("status")
    assert_predicate status, :success?, listed
    assert_match(/^state:\s+signed in/, listed, listed)
  end

  private

    # The probe answers the whole document, so a refusal is legible in the
    # failure rather than an unexplained nil. Poll once a second while the
    # shared steward's other journeys use the same member API.
    LOOP_POLL = 1
    AWAIT_SECONDS = 90

    def await_loop_completion(&probe)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = probe.call
        found = latest["run"]
        return found if found && found["status"] == "completed"
        flunk "the loop never completed; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep LOOP_POLL
      end
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name: the
    # test process inherits the machine's empty locale.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
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

    def sign_in_steward
      @actor.visit("/session/new")
      @page.fill_in "Email", with: @steward.email
      @page.fill_in "Password", with: @steward.password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      assert @page.has_text?("Dashboard")
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
