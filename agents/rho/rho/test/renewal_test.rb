require "test_helper"

# Keeping a connection alive without being asked to. Reactive refresh alone
# cannot do it: a 401 is one undifferentiated type, so every fenced credential
# would cost a failed request first, and a daemon that simply sits still would
# lose its session to the kernel's inactivity window without ever making
# the request that would have told it. Nothing else expires a working
# connection — there is no absolute horizon — so renewing is the whole job.
class RenewalTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-renewal")
    @now = Time.utc(2026, 7, 26, 12, 0, 0)
    @rotations = 0
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # Access tokens live 14 days, which is the lifetime the renewal lead is
  # chosen against.
  ACCESS_TOKEN_LIFETIME = 14 * 24 * 60 * 60

  def authority(failure: nil)
    test = self
    object = Object.new
    object.define_singleton_method(:rotate) do |refresh_token:|
      raise failure if failure

      test.instance_variable_set(:@rotations, test.instance_variable_get(:@rotations) + 1)
      CybrosAgent::DeviceFlow::Credentials.new(
        access_token: "sk-next", executor_access_token: "ek-next", refresh_token: "rt-next",
        token_type: "Bearer", expires_in: ACCESS_TOKEN_LIFETIME
      )
    end
    object
  end

  def oauth(failure: nil)
    CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: "sk-0", executor_access_token: "ek-0", refresh_token: "rt-0",
        token_type: "Bearer", expires_in: ACCESS_TOKEN_LIFETIME
      ),
      authority: authority(failure: failure),
      store: Rho::StateFile.new(File.join(@root, "vault.json")), clock: -> { @now }
    )
  end

  def renewal(credentials = oauth, events: [])
    Rho::Renewal.new(oauth: credentials, clock: -> { @now }, on_event: ->(event) { events << event })
  end

  def test_a_fresh_credential_is_left_alone
    assert_equal :not_due, renewal.run_once
    assert_equal 0, @rotations
  end

  # The one rule has to satisfy both constraints at once: rotate often enough
  # that the inactivity window never bites, and early enough that a
  # week of unreachable Nexus is survivable.
  def test_renewal_happens_a_week_before_expiry_which_is_well_inside_the_inactivity_window
    credentials = oauth
    @now += ACCESS_TOKEN_LIFETIME - Rho::Renewal::RENEWAL_LEAD

    assert_equal :renewed, renewal(credentials).run_once
    assert_equal 1, @rotations

    interval = ACCESS_TOKEN_LIFETIME - Rho::Renewal::RENEWAL_LEAD
    assert_operator interval, :<, 30 * 24 * 60 * 60, "a quiet daemon must never reach the inactivity reap"
    assert_operator Rho::Renewal::RENEWAL_LEAD, :>=, 7 * 24 * 60 * 60, "and must survive a week of outage"
  end

  # Terminal: the lineage is gone, by revocation, by a reuse cascade, or by the
  # inactivity reap. No retry brings it back.
  def test_a_lost_lineage_is_reported_rather_than_retried_into_a_wall
    lost = CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant")
    credentials = oauth(failure: lost)
    @now += ACCESS_TOKEN_LIFETIME

    events = []
    assert_equal :lost, renewal(credentials, events: events).run_once
    assert_equal [:lost], events
  end

  # A throttle or a server failure is exactly what the lead time exists for.
  def test_a_transient_failure_is_deferred_not_escalated
    credentials = oauth(failure: CybrosAgent::DeviceFlow::ServerError.new("upstream"))
    @now += ACCESS_TOKEN_LIFETIME

    assert_equal :deferred, renewal(credentials).run_once
  end

  # The rotation happened; only the record of it failed. The pair in memory is
  # the only live credential, so it must keep being used — reporting this as a
  # failed renewal would invite a retry that presents a spent token.
  def test_a_rotation_that_could_not_be_written_down_says_exactly_that
    credentials = oauth
    @now += ACCESS_TOKEN_LIFETIME
    credentials.instance_variable_set(:@store, FailingStore.new(File.join(@root, "vault.json")))

    assert_equal :not_durable, renewal(credentials).run_once
  end

  # One inner file keeps the test double's failure behavior straightforward;
  # production StateFile objects for one path share an in-process lock.
  class FailingStore
    def initialize(path) = @inner = Rho::StateFile.new(path)
    def description = @inner.description
    def read = @inner.read
    def with_lock(&) = @inner.with_lock(&)
    def write(_document) = raise(Errno::ENOSPC)
  end
end
