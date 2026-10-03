# Run only after test workers stop. Uses the normal application schema, real
# Conversation/Turn/Variant/Body/Fragment owners and production Search SQL.
# Bulk synthetic fixture creation is a query-plan diagnostic, not writer or
# throughput measurement. All synthetic rows roll back; physical index
# maintenance performed by the diagnostic need not roll back.
# Run from nexus/ against a migrated test database with the standard fixtures
# already loaded (member, curator, Shared). This script never loads or purges fixtures.
# RAILS_ENV=test RAILS_TEST_APP_DB_NAME=nexus_search_plan_test \
# RAILS_TEST_CABLE_DB_NAME=nexus_search_plan_cable_test \
# bin/rails runner test/manual/conversation_search_plan.rb
abort "explicit test database required" unless Rails.env.test? && ENV["RAILS_TEST_APP_DB_NAME"].present?
reader = User.members.find_by!(handle: "member")
writer = User.members.find_by!(handle: "curator")
workspace = Workspace.data_accessible_to(reader).browsable.find_by!(name: "Shared")
raise "probe principals must share an account" unless reader.account_id == writer.account_id && reader.account_id == workspace.account_id
account = reader.account
now = Time.current

ApplicationRecord.transaction do
  actor = Actors::Resolve.member(account: account, user: writer)
  conversations = 80.times.map do |index|
    Conversation.create!(workspace: workspace, creating_user: writer, answering_user: writer,
      title: index % 17 == 0 ? "人工智能 running query-plan #{index}" : "Query-plan notes #{index}",
      access_default: index.even? ? "full" : "none", timeline_position_head: 125,
      archived_at: index % 10 == 0 ? now : nil)
  end
  # Explicit ACL arms beside default-open/default-none: a denied named entry
  # overrides the default; a read entry admits a otherwise private room.
  ConversationAccessEntry.create!(account: account, conversation: conversations[2], user: reader, level: "none")
  ConversationAccessEntry.create!(account: account, conversation: conversations[3], user: reader, level: "read")
  text_for = ->(position) { (position + 1) % 31 == 0 ? "Research 人工智能 is running and searches continue." : "Ordinary garden notes, weather and books." }
  texts = [text_for.call(0), text_for.call(30)]
  projections = ApplicationRecord.with_connection do |connection|
    texts.to_h { |text| [text, Nexus::SearchTerms.for([text], connection: connection)] }
  end
  fragments = texts.to_h do |text|
    payload = { "text" => text }
    address = Nexus::ContentAddress.for(account_id: account.id, payload: payload)
    fragment = ContentFragment.find_or_create_by!(account: account, digest: address.digest) { |row| row.payload = payload }
    [text, fragment.id]
  end

  turns = ConversationTurn.insert_all!(conversations.flat_map do |conversation|
    125.times.map do |position|
      { account_id: account.id, conversation_id: conversation.id, position: position,
        kind: "message", role: "user", status: "completed", speaker_actor_id: actor.id,
        control_owner_user_id: writer.id, answering_user_id: writer.id,
        visibility: position == 30 ? "hidden" : (position == 61 ? "excluded_from_context" : "visible"),
        created_at: now, updated_at: now }
    end
  end, returning: %w[id conversation_id position]).to_a
  positions = turns.to_h { |turn| [turn.fetch("id"), turn.fetch("position")] }
  variants = ConversationTurnVariant.insert_all!(turns.map do |turn|
    { account_id: account.id, conversation_turn_id: turn.fetch("id"), position: 0,
      status: "completed", source: "manual", created_at: now, updated_at: now }
  end, returning: %w[id conversation_turn_id]).to_a
  ApplicationRecord.with_connection do |connection|
    ids = conversations.map(&:id).join(",")
    connection.execute(<<~SQL)
      UPDATE conversation_turns t SET active_variant_id = v.id
      FROM conversation_turn_variants v
      WHERE v.conversation_turn_id = t.id AND v.position = 0 AND t.conversation_id IN (#{ids})
    SQL
  end
  body_rows = variants.map do |variant|
    text = text_for.call(positions.fetch(variant.fetch("conversation_turn_id")))
    { account_id: account.id, conversation_turn_variant_id: variant.fetch("id"), role: "content",
      readable_text: text, byte_size: text.bytesize, search_terms: projections.fetch(text),
      sealed_at: now, created_at: now, updated_at: now }
  end
  bodies = ContentBody.insert_all!(body_rows, returning: %w[id readable_text]).to_a
  ContentBodyEntry.insert_all!(bodies.map do |body|
    { account_id: account.id, content_body_id: body.fetch("id"),
      content_fragment_id: fragments.fetch(body.fetch("readable_text")), position: 0,
      created_at: now, updated_at: now }
  end)

  # Three genuine forks share their prefix, then one inherited hit is concealed.
  forks = [4, 6, 8].map do |index|
    source = conversations.fetch(index)
    turn = source.conversation_turns.order(:position).last
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: source, turn_public_id: turn.public_id, variant_public_id: nil,
      acting_user: reader, title: "Fork query-plan #{index}"))
    raise "fork refused: #{result.outcome}" unless result.accepted?
    result.value
  end
  concealed = conversations.fetch(4).conversation_turns.find_by!(position: 61)
  override = ConversationTurnOverride.find_or_initialize_by(conversation: forks.first, conversation_turn: concealed)
  override.update!(visibility: "visible", deleted_at: now)

  ApplicationRecord.with_connection do |connection|
    %w[conversations conversation_turns conversation_turn_variants content_bodies content_body_entries
       conversation_ancestries conversation_turn_overrides conversation_access_entries].each do |table|
      connection.execute("ANALYZE #{table}")
    end
    puts "Synthetic source graph: #{conversations.length} conversations, #{turns.length} base turns, #{bodies.length} base bodies, #{forks.length} actual forks."
    terms = Nexus::SearchTerms.for(["人工智能 runs"], connection: connection)
    query = Conversations::History::Search.new(workspace: workspace, user: reader, query: "人工智能 runs", limit: 20)
    sql = query.send(:sql, connection, terms)
    puts "SHIPPED SEARCH SQL:"
    puts sql
    puts "DEFAULT PLANNER, actual SQL, ANALYZE/BUFFERS; synthetic query-shape evidence, not a production performance claim:"
    puts connection.select_values("EXPLAIN (ANALYZE, BUFFERS, COSTS ON, TIMING OFF) #{sql}")

    # Separate bulk insertion's pending-list cost from the same query after
    # maintenance. Keep both plans; neither forces an index or changes a GUC.
    cleaned_pages = connection.select_value(
      "SELECT gin_clean_pending_list('index_content_bodies_on_search_terms'::regclass)"
    )
    puts "Body GIN pending pages cleaned: #{cleaned_pages}"
    puts "AFTER BODY GIN PENDING CLEANUP, identical SQL and default planner:"
    puts connection.select_values("EXPLAIN (ANALYZE, BUFFERS, COSTS ON, TIMING OFF) #{sql}")

    allowed = Conversation.visible_to(reader, workspace: workspace).unarchived.working.where(parent_conversation_id: nil).pluck(:public_id)
    matches = []
    after = nil
    # Each opaque cursor advances through this transaction's fixed, finite graph.
    loop do
      page = Conversations::History::Search.call(workspace: workspace, user: reader,
        query: "人工智能 runs", limit: 20, after: after)
      matches.concat(page.fetch(:matches))
      after = page.dig(:pagination, :next_after)
      break unless after
    end
    raise "unreadable conversation leaked" unless matches.all? { |row| allowed.include?(row.fetch("conversation_public_id")) }
    identities = matches.map { |row| row.values_at("conversation_public_id", "turn_public_id", "field") }
    raise "duplicate keyset result" unless identities.uniq.length == identities.length
    raise "inheritance not exercised" unless matches.any? { |row| row.fetch("inherited") }
    raise "source fixture did not exercise multiple pages" unless matches.length > 20
    puts "Actual service pages: #{matches.length} matches; ACL membership, inherited hits and keyset uniqueness verified."
  end
  raise ActiveRecord::Rollback
end
puts "Rolled back all synthetic graph rows."
