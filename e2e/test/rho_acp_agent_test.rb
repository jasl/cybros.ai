require "test_helper"
require "base64"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "timeout"
require "tmpdir"
require "rho/version"
require "support/acp_client"
require "support/actor_provisioning"
require "support/ceremony"
require "support/mcp_fixture/declarations"
require "support/mcp_fixture/host"
require "support/mock_llm/directives"
require "support/red_square_png"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# An editor drives `rho-acp` over stdio with initialization, sessions, prompts, permissions,
# elicitation, cancellation, restoration, modes, configuration, commands, filesystem access and MCP
# servers. The scripted client checks each translation against the kernel member plane and daemon
# state. Mock scripts use explicit replies so echoed context cannot grow between turns. Protocol
# documents, identifiers, error codes and update kinds are exact; model-generated wording is not.
#
# ONE CEREMONY PER FILE, ONE GRANT (the `rho_run` shape): one full-mode
# daemon on a PRODUCT-SHAPED home — no rho-dev, so every read here is the
# kernel's member plane, rho's product verbs (`env`, `mcp`) or the
# daemon's door; the one extension named is `rho/mcp`, the product gem
# the servers row needs — its own home, its default root a directory the
# journey owns; every case opens its own sessions, so the cases run in
# any order; two cases restart the SAME home (an eviction, a stopped
# daemon) and leave it running. The surface runs under rho-acp's OWN
# bundle (the three Bundler names; a child inheriting rho's lock would
# rewrite it) with `RHO_HOME` the lane's home.
class RhoAcpAgentTest < Minitest::Test
  Methods = E2E::AcpClient::Methods
  Update = Methods::SessionUpdate
  Code = Methods::ErrorCode
  RemoteError = E2E::AcpClient::RemoteError

  MODEL = "dev/mock-text".freeze
  # THE TEXT-ONLY TWIN (the mock catalog's `dev/mock-text-only`): the one
  # other enabled row whose name says which row a turn ran on.
  OTHER_MODEL = "dev/mock-text-only".freeze
  RHO_ACP_ROOT = File.expand_path("../../agents/rho/rho-acp", __dir__)
  # The surface's bundle, pinned and frozen (Bundler 4 exports the lock
  # beside the Gemfile; a child naming another Gemfile names its lock).
  SURFACE_BUNDLE_ENV = {
    "BUNDLE_GEMFILE" => File.join(RHO_ACP_ROOT, "Gemfile"),
    "BUNDLE_LOCKFILE" => File.join(RHO_ACP_ROOT, "Gemfile.lock"),
    "BUNDLE_FROZEN" => "true",
  }.freeze
  # A prompt turn waits as every mock journey's watch does: twice the
  # kernel's recovery floor, so a wake the kernel lost is not a red here.
  PROMPT_TIMEOUT = 2 * E2E::RhoDaemon::KERNEL_FLOOR_SECONDS
  SPAWN_TIMEOUT = 30
  EXIT_TIMEOUT = 20
  POLL = 1
  AWAIT_SECONDS = 90
  # A tool the cancel ends: three holds, never its own clock.
  SLEEP_SECONDS = 3 * E2E::RhoDaemon::HOLD_SECONDS
  # A tool that ends on its own AFTER the reader left: one hold.
  OUTLIVE_SECONDS = E2E::RhoDaemon::HOLD_SECONDS
  # (iii)'s SLOW WRITER (the `rho_run` stream case's shape): the mock's
  # per-chunk delay at its clamp over a reply of some twenty chunks, so
  # the deltas land on a reader the surface holds.
  STREAM_CHUNK_DELAY = E2E::MockLLM::Directives::DEFAULT_MAX_SLOW_SECONDS
  STREAM_WORDS = "as a stream, one chunk at a time, so that the editor watching the wire sees the words land " \
    "delta by delta under one message id before the turn settles and the prompt answers end_turn; the " \
    "surface relays each delta the daemon fans as it lands".freeze
  # The kernel's frame before every summary a model reads
  # (`Conversations::Compaction::REREAD_RULE`).
  REREAD_RULE = "This summary replaces earlier history and carries no data values: " \
    "re-read any file, output or result it mentions before you use it.".freeze
  RUNNER_SENTENCE = "this rho runs in mode runner: it opens no conversations".freeze
  NO_DAEMON_SENTENCE = "no local daemon is running; start one with `rho server`".freeze
  QUESTION = "which database?".freeze

  # --- THE DOCUMENTS THE DESIGN FIXES ---
  AGENT_INFO = { "name" => "rho", "title" => "rho", "version" => Rho::VERSION }.freeze
  AGENT_CAPABILITIES = {
    "loadSession" => true,
    "promptCapabilities" => { "image" => true, "audio" => false, "embeddedContext" => true },
    "mcpCapabilities" => { "http" => true, "sse" => false },
    "sessionCapabilities" => { "resume" => {}, "close" => {}, "additionalDirectories" => {} },
  }.freeze
  NEXUS_METHOD = { "id" => "nexus", "name" => "Connect this machine to Nexus", "description" => "opens the device page" }.freeze
  TERMINAL_METHOD = { "id" => "connect", "type" => "terminal", "name" => "Connect from the terminal", "args" => ["connect"] }.freeze
  INITIALIZE_DOCUMENT = {
    "protocolVersion" => Methods::PROTOCOL_VERSION, "agentInfo" => AGENT_INFO, "agentCapabilities" => AGENT_CAPABILITIES,
    "authMethods" => [NEXUS_METHOD],
  }.freeze
  MODE_ROWS = [
    { "id" => "bypass", "name" => "Bypass", "description" => "every call runs; rho's deny floor stands" },
    { "id" => "ask", "name" => "Ask", "description" => "hold every effect for your approval; reads run" },
    { "id" => "rules", "name" => "Rules", "description" => "refuse every call no rule allows; reads run" },
  ].freeze
  MODES = { "currentModeId" => "bypass", "availableModes" => MODE_ROWS }.freeze
  PERMISSION_OPTIONS = [
    { "optionId" => "allow", "name" => "Allow", "kind" => Methods::PermissionOptionKind::ALLOW_ONCE },
    { "optionId" => "always", "name" => "Always allow — rho remembers this call's shape until its daemon restarts",
      "kind" => Methods::PermissionOptionKind::ALLOW_ALWAYS },
    { "optionId" => "reject", "name" => "Reject", "kind" => Methods::PermissionOptionKind::REJECT_ONCE },
  ].freeze
  ANSWER_SCHEMA = { "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"] }.freeze
  SURFACE_COMMANDS = %w[retry abandon compact].freeze
  # The three-item checklist `todo_write` writes and the `plan` mirrors.
  TODOS = [
    { "content" => "Add the CLI entry", "status" => "completed" },
    { "content" => "Parse the input file", "status" => "in_progress" },
    { "content" => "Write the tests", "status" => "pending" },
  ].freeze

  World = Struct.new(:daemon, :home, :root, :steward, :actor, :workspace_public_id, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      steward = E2E::ActorProvisioning.world(base_url).rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-acp-agent-e2e")
      # THE DAEMON'S DEFAULT ROOT, outside the home (a protected root) and
      # never the checkout: what `rho env` names, and what no session moves.
      root = File.realpath(Dir.mktmpdir("rho-acp-agent-root"))
      write_product_settings!(home)
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, tools_root: root)
      @world = World.new(daemon: daemon, home: home, root: root, steward: steward, actor: actor)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @world
    end

    # A PRODUCT HOME: no rho-dev, no operator verb; `rho/mcp` is the
    # product gem the editor's servers land on (a daemon without it
    # answers 422 `mcp_unavailable`), named as any product home names it.
    def write_product_settings!(home)
      File.write(File.join(home, "settings.json"), JSON.generate({ "extensions" => ["rho/mcp"] }), encoding: Encoding::UTF_8)
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

      begin
        world.daemon&.stop
      rescue StandardError => error
        warn "Could not stop the rho daemon: #{error.class}: #{error.message}"
      end
      [world.home, world.root].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
    end
  end

  Minitest.after_run { RhoAcpAgentTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @workspace_public_id = @world.workspace_public_id
    @scratch = Dir.mktmpdir("rho-acp-agent-scratch")
    @clients = []
    @dirs = []
  end

  def teardown
    unless passed?
      @clients.each_with_index { |client, index| warn_text(client.stderr, "rho-acp ##{index} stderr") }
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      warn_log(@mcp_fixture_log, "http mcp fixture")
      %i[runner jobs].each do |host|
        warn_log(E2E.hosts.log_path(host), "nexus #{host}")
      rescue StandardError
        nil
      end
    end
  rescue StandardError => error
    warn "Could not capture the rho_acp_agent E2E logs: #{error.class}: #{error.message}"
  ensure
    @clients.each(&:close)
    # HYGIENE, EVERY CASE: stdout is the wire and nothing else — every line the surface wrote parses
    # as one JSON-RPC message.
    @clients.each { |client| assert_wire_only(client) } if passed?
    E2E::McpFixture::Host.stop(@mcp_fixture_pid) if @mcp_fixture_pid
    [@scratch, *@dirs].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end
end

# Keep one discovered journey and one shared daemon for every protocol concern.
require_relative "rho_acp_agent/support"
require_relative "rho_acp_agent/protocol"
require_relative "rho_acp_agent/sessions"
require_relative "rho_acp_agent/interaction"
require_relative "rho_acp_agent/tools"
