require "test_helper"

class Executors::PoolTest < ActiveSupport::TestCase
  test "pool membership batches manager eligibility without changing scope or shutdown filtering" do
    owner = users(:owner)
    member = users(:member)
    curator = users(:curator)
    assert_equal :role_changed, member.change_role(to: :admin)
    assert_equal :role_changed, curator.change_role(to: :admin)

    own = connect_provider(identifier: "own-private", tools: ["net_fetch"], assignment_scope: :user_private)
    shared = connect_provider(identifier: "curator-wide", tools: ["net_fetch"], manager: curator)
    connect_provider(identifier: "member-private", tools: ["net_fetch"], manager: member, assignment_scope: :user_private)
    pending = connect_provider(identifier: "member-wide", tools: ["net_fetch"], manager: member)
    connect_provider(identifier: "no-credential", tools: ["net_fetch"]).revoke_credentials
    connect_provider(identifier: "revoked", tools: ["net_fetch"]).revoke
    connect_provider(identifier: "other-tool", tools: ["other_tool"])

    ApplicationRecord.uncached do
      assert_queries_match(/FROM "users"/, count: 1) do
        assert_equal [own.id, shared.id, pending.id], Executors::Pool.members("net_fetch", owner).map(&:id)
      end
    end

    assert_equal :removed, member.remove
    assert_equal :restored, member.restore

    ApplicationRecord.uncached do
      assert_queries_match(/FROM "users"/, count: 1) do
        assert_equal [own.id, shared.id], Executors::Pool.members("net_fetch", owner).map(&:id),
          "a still-active address cannot reenter the pool before its shutdown generation is applied"
      end
    end
  end
end
