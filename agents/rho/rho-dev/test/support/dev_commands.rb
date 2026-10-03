require "test_helper"
require "tmpdir"

# Dispatcher registration and daemon fixtures shared by the command tests.
class DevCommandsTest < Minitest::Test
  include RhoTest::CliHarness

  # The commands as `Rho::Dev.register` hands them to the dispatcher: one
  # registration over the test host, the verbs by name; `handlers` is the
  # verb-to-handler view the cases call through.
  def self.commands
    @commands ||= begin
      api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: Rho::Dev::NAME, source: "<test>")
      Rho::Dev.register(api)
      api.commands.to_h { |command| [command.name, command] }
    end
  end

  def self.handlers = @handlers ||= commands.transform_values(&:handler)

  def ops(verb, *args, **options) = self.class.handlers.fetch(verb.to_s).call(cli, args, options)

  def lines = @out.string.lines.map(&:chomp)

  def reset_out = (@out = StringIO.new)

  IDENTITY = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id).new(
    user_public_id: "user-1", executor_public_id: "executor-1", runner_executor_public_id: nil
  )

  # THE PUSHED CHANNEL, FROM THE TERMINAL. `rho follow` is the debuggable
  # half of the stream a page will hold open, and it shipped without a
  # test of its own — the same shape of gap that once put a 500 on the
  # transcript read.
  def followed_run(public_id, tasks:, state:, listeners: nil, snapshot: nil)
    run = Object.new
    run.define_singleton_method(:public_id) { public_id }
    run.define_singleton_method(:backs?) { |id| id == public_id }
    run.define_singleton_method(:child?) { |_id| false }
    run.define_singleton_method(:snapshot) do
      Struct.new(:to_h, :complete).new(snapshot || { public_id: public_id, tasks: tasks }, state[:complete])
    end
    run.define_singleton_method(:turn_settled?) { state[:complete] }
    # THE OTHER FEED'S ENDING: the route closes on both, so a
    # double answers both — settled unless a lane says otherwise.
    run.define_singleton_method(:transcript_settled?) { state.fetch(:transcript, true) }
    run.define_singleton_method(:listen) { |&handler| listeners&.push(handler); :token }
    run.define_singleton_method(:forget) { |_token| nil }
    run.define_singleton_method(:realtime) { nil }
    run.define_singleton_method(:stop) { nil }
    run.define_singleton_method(:stopped?) { false }
    run.define_singleton_method(:host?) { true }
    run.define_singleton_method(:one_shot?) { false }
    run
  end

  # A followed run belongs to a lineage; the daemon holds one through its
  # own verbs rather than a slot a test writes into.
  def hold_run(daemon, run)
    about = Object.new
    daemon.lineage.stop_maintenance
    daemon.lineage.adopt(identity: IDENTITY, credentials: about)
    daemon.lineage.install_run(about, run)
  end

  # The same hold, under a lineage that answers the member token: a verb
  # that reads a page through the daemon's member plane AND listens to its
  # stream (`transcript --follow`) needs both seams on one daemon.
  def member_hold_run(daemon, run, token: NexusDoubles::MEMBER_TOKEN)
    about = Object.new
    about.define_singleton_method(:member_credential) { token }
    about.define_singleton_method(:executor_credential) do
      raise CybrosAgent::Error, "this fixture holds no transport credential"
    end
    about.define_singleton_method(:runner_credential) do
      raise CybrosAgent::Credentials::PlaneUnavailable, "this fixture holds no runner credential"
    end
    about.define_singleton_method(:lineages) { [] }
    about.define_singleton_method(:runner?) { false }
    about.define_singleton_method(:agent?) { true }
    daemon.lineage.stop_maintenance
    daemon.lineage.adopt(identity: IDENTITY, credentials: about)
    daemon.lineage.commit_workspace(about, Rho::Daemon::Lineage::Workspace.adopted(public_id: "ws-1", name: "W"))
    daemon.lineage.install_run(about, run)
  end

  def frame(type, payload) = Struct.new(:type, :payload).new(type, payload)
end
