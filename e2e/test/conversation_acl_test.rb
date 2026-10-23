require "test_helper"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/peer_program"
require "support/realtime_lane"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/red_square_png"
require "support/steward_session"
require "stringio"

# rho creates a restricted Conversation and changes participant access through its CLI.
# An independent SDK peer observes the resulting allowed and concealed reads in rho's dedicated
# workspace. Request/service tests own the complete ACL door and mutation matrices.
class ConversationAclTest < Minitest::Test
  include E2E::RealtimeLane

  MODEL = "dev/mock-text".freeze
  POLL = 1
  AWAIT_SECONDS = 90

  World = Struct.new(:daemon, :home, :steward, :rho_workspace_public_id, :peer_b, keyword_init: true)

  class << self
    attr_reader :world

    def boot_world!(base_url)
      provisioning = E2E::ActorProvisioning.world(base_url)
      steward = provisioning.rho_steward
      actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
      home = Dir.mktmpdir("rho-conversation-acl-e2e")
      daemon = E2E::RhoDaemon.new(base_url: base_url, home: home)
      @world = World.new(daemon: daemon, home: home, steward: steward)
      daemon.start
      E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
      @world.rho_workspace_public_id = await_workspace_adopted(daemon)
      E2E.enable_dev_lane!
      E2E.hosts.start
      @world.peer_b = E2E::PeerProgram.pair(base_url: base_url, actor: actor, name: "acl-b")
      @world
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
      FileUtils.remove_entry(world.home) if world.home && File.directory?(world.home)
    end
  end

  Minitest.after_run { ConversationAclTest.stop_world! }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world || self.class.boot_world!(@base_url)
    @daemon = @world.daemon
    @steward = @world.steward
    @b = @world.peer_b
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
  end

  def teardown
    return if passed?

    warn_log(@daemon&.log_path, "rho daemon stdout")
    warn_log(@daemon&.rho_log_path, "rho structured log")
  rescue StandardError => error
    warn "Could not capture the conversation ACL E2E logs: #{error.class}: #{error.message}"
  end

  # Through rho in its dedicated workspace, where reads are
  # never fenced so every 404 → 200 below is the ACL's alone. `rho do
  # --restricted` opens `none` with the STEWARD at `full` (rho's entry, not
  # the kernel's: the steward reads the row and its side); B finds the
  # conversation, its loop and the loop index absent; `rho conversation
  # participants` prints the carrier; `add B read` flips the doors open
  # (conversation and loop alike); `rm B` closes them; `default read` opens
  # them for everyone. Posting permissions belong to the request tests;
  # here a posting refusal could also come from the dedication fence.
  def test_rho_do_restricted_and_rho_conversation_participants_flip_the_doors_in_rhos_workspace
    output, status = @daemon.cli("do", "!mock -- hello", "--model", MODEL, "--restricted", "--dir", project)
    assert_predicate status, :success?, "rho do --restricted failed:\n#{output}"
    conversation, loop_id = %w[conversation run].map { |line| output[/^#{line}:\s+(\S+)/, 1] }
    refute_includes [conversation, loop_id], nil, "rho do printed no conversation or loop id:\n#{output}"
    assert_match(/^access:\s+none \(restricted\)$/, output, "the answer prints the access line:\n#{output}")
    rho_ws = @world.rho_workspace_public_id

    steward_view = @steward_client.workspace(rho_ws).conversation(conversation).fetch
    assert_equal "none", steward_view.access.default
    assert_equal "full", steward_view.access.level_for(@steward.public_id), "the steward's entry is rho's"

    b_ws = @b.client.workspace(rho_ws)
    refute_includes b_ws.conversations.list(limit: 50).items.map(&:public_id), conversation
    assert_raises(CybrosAgent::Api::NotFound) { b_ws.conversation(conversation).fetch }
    assert_raises(CybrosAgent::Api::NotFound, "the loop is a second door onto its conversation") do
      b_ws.run(loop_id).fetch
    end
    refute_includes b_ws.runs.list(limit: 50).items.map(&:public_id), loop_id, "the loop index conceals it too"

    printed, status = @daemon.cli("conversation", "participants", conversation)
    assert_predicate status, :success?, "rho conversation participants failed:\n#{printed}"
    assert_match(/^default:\s+none$/, printed, printed)
    # The listing's columns: level, @handle, id, kind, name.
    assert_match(/^  full  @\S+  #{Regexp.escape(@steward.public_id)}  human  /, printed, printed)

    printed, status = @daemon.cli("conversation", "participants", conversation, "add", @b.public_id, "read")
    assert_predicate status, :success?, "rho conversation participants add failed:\n#{printed}"
    assert_match(/^  read  @\S+  #{Regexp.escape(@b.public_id)}  agent  /, printed, printed)
    assert_includes b_ws.conversations.list(limit: 50).items.map(&:public_id), conversation, "the 404 → 200 flip"
    assert_equal "read", b_ws.conversation(conversation).fetch.access.level_for(@b.public_id)
    assert_equal loop_id, b_ws.run(loop_id).fetch.public_id, "the loop door follows the conversation's level"
    assert_includes b_ws.runs.list(limit: 50).items.map(&:public_id), loop_id

    printed, status = @daemon.cli("conversation", "participants", conversation, "rm", @b.public_id)
    assert_predicate status, :success?, "rho conversation participants rm failed:\n#{printed}"
    assert_match(/\(no named participants\)|^default:/, printed, printed)
    refute_match(/#{Regexp.escape(@b.public_id)}/, printed, "B's row is gone")
    assert_raises(CybrosAgent::Api::NotFound, "rm closes the door again") { b_ws.conversation(conversation).fetch }
    assert_raises(CybrosAgent::Api::NotFound) { b_ws.run(loop_id).fetch }

    printed, status = @daemon.cli("conversation", "participants", conversation, "default", "read")
    assert_predicate status, :success?, "rho conversation participants default failed:\n#{printed}"
    assert_match(/^default:\s+read$/, printed, printed)
    assert_equal "read", b_ws.conversation(conversation).fetch.access.level_for(@b.public_id), "the default admits B"

    # The side of a restricted row: rho forks as the answerer; the steward's `full` entry is
    # copied, so the steward reads the side; under the `read` default B reads it too.
    await_run_status(rho_ws, loop_id, "completed")
    opened, status = @daemon.cli("side", conversation)
    assert_predicate status, :success?, "rho side failed:\n#{opened}"
    listed, status = @daemon.cli("followers", "--side")
    assert_predicate status, :success?, "rho loops --side failed:\n#{listed}"
    side_id = listed.lines.grep(/side of #{Regexp.escape(conversation)}$/).first.to_s[/\A(\S+)/, 1]
    refute_nil side_id, "no side listed for the restricted row:\n#{listed}"
    said, status = @daemon.cli("say", side_id, "what did I ask?")
    assert_predicate status, :success?, "rho say on the Side failed:\n#{said}"
    side = @steward_client.workspace(rho_ws).conversation(side_id)
    await("the restricted Side's reply") do
      side.turns.list.items.find do |turn|
        !turn.inherited && !turn.reference? && turn.kind == "direct_reply" && turn.status == "completed"
      end
    end
    side_view = side.fetch
    assert_predicate side_view, :side?
    assert_equal "full", side_view.access.level_for(@steward.public_id), "the steward reads rho's side"
    assert_equal "read", b_ws.conversation(side_id).fetch.access.level_for(@b.public_id)
  end

  private

    def await_run_status(workspace_public_id, loop_id, status)
      await("the loop #{loop_id} never reached #{status}") do
        row = @steward_client.workspace(workspace_public_id).run(loop_id).fetch
        row if row.status == status
      end
    end

    def await(message)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    def project
      @project ||= File.join(@world.home, "project").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    LOG_TAIL_LINES = 80

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
