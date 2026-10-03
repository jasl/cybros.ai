require "test_helper"

# THE INITIAL BINDING: the runner the creator NAMES, else none — the kernel infers no execution host
# (the creator names the runner; an unnamed runner leaves the host unbound). A name is refused
# unless it is a live runner-kind row eligible for the principal: eligibility is a row fact —
# active, credential ready, not shutdown-pending, in scope — never an announcement: an agent
# application's address is never a binding however much it announced, and a tools provider never is.
class Executors::InitialRunnerTest < ActiveSupport::TestCase
  setup do
    @owner = users(:owner)
    @member = users(:member)
    @agent = users(:agent)
  end

  def runner(identifier, manager: @owner, assignment_scope: :account_wide)
    connect_runner(
      manager: manager, runner_identifier: identifier, assignment_scope: assignment_scope
    ).executor_access_token.task_executor
  end

  def bind(requested: nil, principal: @member)
    Executors::InitialRunner.for(requested: requested, principal: principal)
  end

  def assert_refused(decision, message = nil)
    assert_predicate decision, :refused?, message
    assert_equal Executors::InitialRunner::NOT_ELIGIBLE, decision.error_key, message
  end

  def assert_unbound(decision, message = nil)
    refute_predicate decision, :refused?, message
    assert_nil decision.executor, message
  end

  test "no request binds none, whether no runner, one or two are eligible" do
    assert_unbound bind, "no runner anywhere"

    runner("wide-1")
    assert_unbound bind, "one eligible runner is still not a binding: the kernel infers none"
    assert_unbound bind(requested: ""), "a blank request is no request"

    runner("wide-2")
    assert_unbound bind, "nothing selects an execution host on its own"
  end

  test "a requested eligible runner binds, among any number of candidates" do
    first = runner("wide-1")
    second = runner("wide-2")

    assert_equal first, bind(requested: first.public_id).executor
    assert_equal second, bind(requested: second.public_id).executor
  end

  test "a request naming a runner private to another Human is refused" do
    private_runner = runner("private-1", assignment_scope: :user_private)

    assert_refused bind(requested: private_runner.public_id, principal: @member)
  end

  test "a revoked runner, a tools provider and an announced agent address are refused by name" do
    revoked = runner("gone")
    revoked.revoke
    provider = connect_provider(identifier: "provider-1", tools: ["read_file"])
    address = task_executors(:address)
    address.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])

    assert_refused bind(requested: revoked.public_id)
    assert_refused bind(requested: provider.public_id)
    assert_refused bind(requested: address.public_id, principal: @agent),
      "an announced agent address is never a binding (the deleted arm's own case)"
    assert_refused bind(requested: "not-a-public-id")
  end

  # The schema permits one Account, so initial-runner selection does not carry a second account
  # selector. Eligibility is determined by the runner row and current principal.
  test "the account is a singleton, so a runner of another account is unreachable" do
    assert_raises(ActiveRecord::RecordNotUnique) { Account.create!(name: "Other") }
  end

  test "an agent principal reaches its steward's private runner by name, never unnamed" do
    private_runner = runner("private-1", assignment_scope: :user_private)

    assert_equal private_runner, bind(requested: private_runner.public_id, principal: @agent).executor,
      "eligibility through the steward, a row fact"
    assert_unbound bind(principal: @agent), "the one eligible row is not inferred"
  end

  # The principal a conversation's binding is judged for is its ANSWERER
  # (`Conversation#answering_user`): a runner private to the answerer's steward binds for it, and a
  # Human it does not answer to is refused.
  test "a private runner binds for the agent its manager stewards and for no other Human" do
    private_runner = runner("owner-private", assignment_scope: :user_private)

    bound = bind(requested: private_runner.public_id, principal: @agent)
    refute_predicate bound, :refused?
    assert_equal private_runner, bound.executor
    assert_refused bind(requested: private_runner.public_id, principal: @member)
  end
end
