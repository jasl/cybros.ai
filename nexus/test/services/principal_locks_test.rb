require "test_helper"
require_relative "../test_helpers/agent_membership_test_helper"

# C2-4 A12: the within-table order the table ladder cannot see.
#
# The ladder ranks TABLES, and every row here is `users` — so the order among
# them lives nowhere except this helper and the tests beside it.
class PrincipalLocksTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup { @account = accounts(:cybros) }

  test "an agent principal is locked before the humans it derives from" do
    steward = users(:member)
    agent = create_agent_member(steward: steward)

    locked = capture_locked_users { PrincipalLocks.descend(steward, agent) }

    assert_equal [agent.id, steward.id], locked,
      "the agent's authority derives from its steward, so it is taken first"
  end

  test "humans are locked by ascending id whatever order they arrive in" do
    first, second = [users(:owner), users(:member)].sort_by(&:id)

    locked = capture_locked_users { PrincipalLocks.descend(second, first) }

    assert_equal [first.id, second.id], locked
  end

  # Two instances of one row are one lock. The previous per-command copies
  # relied on the caller passing the SAME object; Active Record's identity is
  # class plus id, so this holds across instances.
  test "one principal named twice is locked once" do
    member = users(:member)

    locked = capture_locked_users { PrincipalLocks.descend(member, User.find(member.id)) }

    assert_equal [member.id], locked
  end

  test "nothing to lock is not an error" do
    assert_empty capture_locked_users { PrincipalLocks.descend(nil, []) }
  end

  private

    # The lock order as the database saw it, read from the SQL the block
    # actually issued rather than from the arguments it was given.
    def capture_locked_users(&block)
      locked = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next unless payload[:sql].match?(/FROM "users".*FOR UPDATE/m)

        # `lock!` binds the id rather than inlining it, so the order lives in
        # the bind values, not the SQL text. The id is the first bind; the
        # second is the `LIMIT`.
        locked << Array(payload[:type_casted_binds]).first
      end
      ApplicationRecord.transaction do
        block.call
        raise ActiveRecord::Rollback
      end
      locked
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
