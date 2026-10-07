require "test_helper"

# THE HANDLE: every member carries a NAME beside its identity — `[a-z0-9_-]{2,32}`, unique per
# account, normalized the way an email is. A Human's default is derived from its display name; an
# agent's is the kernel's pick from the shipped name table, suffixed on collision. `addressed_by` is
# the ONE resolver: `@handle`, `handle` or a public id, the account's members alone.
class UserHandleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def human(display_name, handle: nil, account: @account)
    identity = account.identities.create!(email: "#{SecureRandom.hex(4)}@example.com", password: "password",
      password_confirmation: "password")
    account.users.create!(kind: :human, role: :member, identity: identity, display_name: display_name,
      handle: handle)
  end

  def agent(display_name = "Helper", handle: nil, steward: @owner)
    create_agent_member(steward: steward, display_name: display_name).tap do |member|
      member.update!(handle: handle) if handle
    end
  end

  test "the fixtures carry stable user handles" do
    assert_equal "owner", @owner.handle
    assert_equal "fixture-agent", users(:agent).handle
    assert_equal "system", users(:system).handle
  end

  test "a handle is normalized (strip, downcase) and judged by the one format" do
    member = human("Ada", handle: "  Ada_Lovelace-2 ")
    assert_equal "ada_lovelace-2", member.handle

    ["a", "-lead", "_lead", "has space", "ünïcode", "a" * 33, "", nil].each do |bad|
      member.handle = bad
      assert_not member.valid?, bad.inspect
      assert_includes member.errors.details.fetch(:handle).map { _1[:error] }, bad.blank? ? :blank : :invalid
    end
    member.handle = "a" * 32
    assert_predicate member, :valid?
  end

  test "a handle is unique per account: the validation answers taken, the index is the arbiter" do
    human("Ada", handle: "ada")
    error = assert_raises(ActiveRecord::RecordInvalid) { human("Ada Two", handle: "ADA") }
    assert_includes error.record.errors.details.fetch(:handle).map { _1[:error] }, :taken

    index = User.connection.indexes("users").find { |row| row.columns == %w[account_id handle] }
    assert index.unique, "unique per account, never Nexus-wide: the account is the tenancy boundary"
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.where(id: users(:curator).id).update_all(handle: "ada")
    end
  end

  test "the derivation is parameterize's: transliterate, downcase, runs outside [a-z0-9_-] to one dash, trimmed, capped" do
    assert_equal "ada-lovelace", User::Handle.derive("Ada  Lovelace")
    assert_equal "jose-nunez", User::Handle.derive("José Núñez")
    assert_equal "r2-d2", User::Handle.derive("--R2.D2!!")
    assert_equal "ada_lovelace", User::Handle.derive("Ada_Lovelace"), "an underscore is a handle character and survives"
    assert_equal "x" * 32, User::Handle.derive("x" * 40)
    assert_nil User::Handle.derive("日本語"), "nothing transliterable leaves no base"
    assert_nil User::Handle.derive("_"), "one character is below the floor"
  end

  test "the first free candidate: the base, then -2, -3 …, the suffix always fitting the cap" do
    assert_equal "lark", User::Handle.first_free("lark", Set.new)
    assert_equal "lark-2", User::Handle.first_free("lark", Set["lark"])
    assert_equal "lark-4", User::Handle.first_free("lark", Set["lark", "lark-2", "lark-3"])
    long = "y" * 32
    assert_equal "#{"y" * 30}-2", User::Handle.first_free(long, Set[long])
  end

  test "a Human created without a handle takes the derived default, suffixed on collision, user-n when nothing derives" do
    first = human("Grace Hopper")
    second = human("Grace Hopper")
    assert_equal "grace-hopper", first.handle
    assert_equal "grace-hopper-2", second.handle
    assert_equal "user", human("日本語").handle
    assert_equal "user-2", human("日本語").handle
  end

  test "the default's collision set is every handle of the account: a capped base still finds its -n" do
    name = "z" * 32
    first, second, third = Array.new(3) { human(name) }
    assert_equal "z" * 32, first.handle
    assert_equal "#{"z" * 30}-2", second.handle
    assert_equal "#{"z" * 30}-3", third.handle, "the shortened candidate is judged against the rows too"
  end

  test "an agent created without a handle takes a word from the shipped table, suffixed on collision" do
    picks = Array.new(5) { agent.handle }
    picks.each do |pick|
      base = pick.sub(/-\d+\z/, "")
      assert_includes Nexus::AgentHandles::WORDS, base, pick
    end
    assert_equal picks.length, picks.uniq.length

    # A word the five draws did not take: a stubbed pick that collided with a
    # draw would answer `<word>-2` first and read as a flake (seed 63929).
    word = (Nexus::AgentHandles::WORDS - picks.map { |pick| pick.sub(/-\d+\z/, "") }).first
    Nexus::AgentHandles.stub(:pick, word) do
      assert_equal word, agent.handle
      assert_equal "#{word}-2", agent.handle
    end
  end

  test "a steward's later change is an ordinary update under the same rules" do
    member = agent
    assert member.update(handle: "Lark")
    assert_equal "lark", member.reload.handle
    assert_not member.update(handle: "owner"), "the owner's handle is taken in this account"
  end

  test "addressed_by resolves @handle, handle or a public id to the account's member, else nothing" do
    member = agent(handle: "lark")
    assert_equal member, User.members.addressed_by(@account.id, "@lark").first
    assert_equal member, User.members.addressed_by(@account.id, "LARK ").first
    assert_equal member, User.members.addressed_by(@account.id, member.public_id).first
    assert_equal @owner, User.members.addressed_by(@account.id, "@owner").first

    assert_nil User.members.addressed_by(@account.id, "@nobody").first
    assert_nil User.members.addressed_by(@account.id, SecureRandom.uuid_v7).first
    assert_nil User.members.addressed_by(@account.id, "@system").first, "the system user is never a member"
    assert_nil User.members.addressed_by(@account.id, "").first
    assert_nil User.members.addressed_by(@account.id, nil).first
    assert_nil User.members.addressed_by(@account.id, "not a handle!").first
    assert_nil User.members.addressed_by(@account.id + 1, "@lark").first, "another account's member is absent"
  end

  # THE COOLDOWN: a released handle is reserved in its account for 14 days — two columns on the row,
  # no table, no sweep; only the LATEST previous name is reserved; the kernel never redirects.
  test "a handle CHANGE stamps the previous handle and when; creation and other saves stamp nothing" do
    member = human("Ada", handle: "ada")
    assert_nil member.previous_handle
    assert_nil member.handle_changed_at

    freeze_time do
      member.update!(handle: "lovelace")
      assert_equal "ada", member.previous_handle
      assert_equal Time.current, member.handle_changed_at
    end

    member.update!(display_name: "Ada L.")
    assert_equal "ada", member.reload.previous_handle, "a save that leaves the handle alone stamps nothing"
  end

  test "a released handle is reserved for the account's other members for 14 days, then free; its releaser retakes it at once" do
    releaser = human("Ada", handle: "ada")
    other = human("Bo", handle: "bo")
    travel_to(3.days.ago) { releaser.update!(handle: "lovelace") }

    other.handle = "ada"
    assert_not other.valid?
    assert_equal [:reserved], other.errors.details.fetch(:handle).map { _1[:error] }
    assert_match(/14 days/, other.errors.full_messages_for(:handle).first)
    assert_predicate User.reserving_handle(@account.id, "ada"), :exists?
    assert_not User.reserving_handle(@account.id, "lovelace").exists?

    assert releaser.update(handle: "ada"), "one's own previous handle never blocks oneself"
    assert_equal "lovelace", releaser.previous_handle, "the retake is a change like any other: it releases the other name"

    travel_to(15.days.ago) { releaser.update!(handle: "lovelace") }
    assert other.update(handle: "ada"), "the cooldown has passed"
  end

  test "the reservation expires at exactly 14 days: reserved one second before, free on the boundary" do
    releaser = human("Ada", handle: "ada")
    other = human("Bo", handle: "bo")
    released_at = Time.current.change(usec: 0)
    travel_to(released_at)
    releaser.update!(handle: "lovelace")
    assert_equal released_at, releaser.reload.handle_changed_at

    travel_to(released_at + User::Handle::COOLDOWN - 1.second)
    assert_not other.update(handle: "ada"), "one second before the boundary the name is still reserved"
    assert_equal [:reserved], other.errors.details.fetch(:handle).map { _1[:error] }

    travel_to(released_at + User::Handle::COOLDOWN)
    assert_not User.reserving_handle(@account.id, "ada").exists?, "the reservation is gone on the boundary"
    assert other.update(handle: "ada"), "on the boundary the name is free"
  end

  test "only the latest previous name is reserved: a second rename releases the first" do
    releaser = human("Ada", handle: "ada")
    other = human("Bo", handle: "bo")
    releaser.update!(handle: "lovelace")
    releaser.update!(handle: "countess")

    assert_equal "lovelace", releaser.previous_handle
    assert other.update(handle: "ada")
    assert_not other.update(handle: "lovelace")
  end

  test "a reservation is the account's, never Nexus-wide: another account's rows reserve nothing here" do
    releaser = human("Ada", handle: "ada")
    releaser.update!(handle: "lovelace")

    # The install is single-tenant (the accounts singleton), so the scope is
    # asked for the other account rather than one being created.
    assert_predicate User.reserving_handle(@account.id, "ada"), :exists?
    assert_not User.reserving_handle(@account.id + 1, "ada").exists?
  end

  test "the creation default skips a reserved name: the derived base and the kernel's pick alike" do
    human("Grace Hopper", handle: "grace-hopper").update!(handle: "amazing-grace")
    assert_equal "grace-hopper-2", human("Grace Hopper").handle

    human("Lark", handle: "lark").update!(handle: "lark-flew")
    Nexus::AgentHandles.stub(:pick, "lark") do
      assert_equal "lark-2", agent.handle
    end
  end

  test "every rename narrates handle_changed on the member: {user_public_id, old, new}; creation narrates nothing" do
    member = human("Ada", handle: "ada")
    assert_empty member.conversation_event_items

    member.update!(handle: "lovelace")

    item = member.conversation_event_items.sole
    assert_equal "handle_changed", item.item_type
    assert_equal({ "user_public_id" => member.public_id, "old" => "ada", "new" => "lovelace" }, item.payload)
    assert_equal({ type: "user", public_id: member.public_id },
      ConversationEventItem::PublicProjection.render(item).fetch(:resource))
  end

  test "an old handle resolves to nobody: the resolver is unchanged, the kernel never redirects a released name" do
    member = human("Ada", handle: "ada")
    member.update!(handle: "lovelace")

    assert_nil User.members.addressed_by(@account.id, "@ada").first
    assert_equal member, User.members.addressed_by(@account.id, "@lovelace").first
  end

  test "the previous handle reaches no model-facing surface: the principal row carries the six keys it had" do
    member = human("Ada", handle: "ada")
    member.update!(handle: "lovelace")

    assert_equal %i[public_id handle kind display_name agent_identifier steward_public_id],
      AgentAPI::PrincipalPresenter.basic(member).keys
  end
end

# THE HANDLE BASE (named sub-agents): a creator that names the base — a named definition's name —
# beats the kernel's name table; the `-N` rule past a collision is the one mechanism.
class UserHandleBaseTest < ActiveSupport::TestCase
  test "handle_base beats the name table and takes -2 past a collision; a base outside the grammar is refused" do
    named = create_agent_member(display_name: "Reviewer").tap { |row| row.update!(handle: "reviewer") }
    assert_equal "reviewer", named.handle

    account = accounts(:cybros)
    row = account.users.create!(kind: :agent, role: :member, steward: users(:owner), display_name: "Reviewer",
      agent_identifier: "rho.x/reviewer", handle_base: "reviewer")
    assert_equal "reviewer-2", row.handle

    docs = account.users.create!(kind: :agent, role: :member, steward: users(:owner), display_name: "Docs",
      agent_identifier: "rho.x/docs", handle_base: "docs")
    assert_equal "docs", docs.handle, "never the name table's random word"

    bad = account.users.new(kind: :agent, role: :member, steward: users(:owner), display_name: "Bad",
      agent_identifier: "rho.x/bad", handle_base: "Not a handle")
    assert_not bad.valid?
    assert_includes bad.errors.details.fetch(:handle).map { _1[:error] }, :invalid
  end
end
