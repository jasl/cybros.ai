# Run after test workers stop, with normal test fixtures already loaded. This
# diagnostic uses actual production queries and 10,000 synthetic owned turns,
# variants, loops and inputs. It is an index-shape check, not a throughput test.
# All synthetic rows and the measured update roll back. ANALYZE is allowed to
# refresh planner statistics; physical database maintenance is not a rollback
# guarantee.
# RAILS_ENV=test RAILS_TEST_APP_DB_NAME=cybros_nexus_rho_memory_test \
# RAILS_TEST_CABLE_DB_NAME=cybros_nexus_rho_memory_cable_test \
# bin/rails runner test/manual/source_work_plan.rb
abort "explicit test database required" unless Rails.env.test? && ENV["RAILS_TEST_APP_DB_NAME"].present?

reader = User.members.find_by!(handle: "member")
workspace = Workspace.data_accessible_to(reader).browsable.find_by!(name: "Shared")
account = reader.account
connection = ApplicationRecord.lease_connection
now = Time.current

capture = lambda do |&block|
  statements = []
  listener = ->(_name, _start, _finish, _id, payload) {
    sql = payload.fetch(:sql).dup
    payload.fetch(:binds, []).each_with_index.to_a.reverse_each do |bind, index|
      sql = sql.gsub("$#{index + 1}", connection.quote(bind.value_for_database))
    end
    statements << sql
  }
  ActiveSupport::Notifications.subscribed(listener, "sql.active_record", &block)
  statements
end
explain = lambda do |label, sql|
  raise "missing captured #{label} query" unless sql

  puts "\n#{label}\n#{sql}"
  puts connection.select_values("EXPLAIN (ANALYZE, BUFFERS, COSTS ON, TIMING OFF) #{sql}")
end

ApplicationRecord.transaction do
  actor = Actors::Resolve.member(account: account, user: reader)
  hosts = 10.times.map do
    Conversation.create!(workspace: workspace, creating_user: reader, answering_user: reader,
      timeline_position_head: 1_000)
  end
  turns = ConversationTurn.insert_all!(10_000.times.map { |index|
    { account_id: account.id, conversation_id: hosts[index / 1_000].id,
      position: index % 1_000, kind: "direct_reply", role: "assistant", status: "completed",
      speaker_actor_id: actor.id, control_owner_user_id: reader.id, answering_user_id: reader.id,
      created_at: now, updated_at: now }
  }, returning: %w[id public_id]).to_a
  variants = ConversationTurnVariant.insert_all!(turns.each_with_index.map { |turn, index|
    { account_id: account.id, conversation_turn_id: turn.fetch("id"), position: 0,
      source: "agent_loop", status: index < 9_000 ? "failed" : "running", created_at: now, updated_at: now }
  }, returning: %w[id]).to_a
  loops = AgentLoop.insert_all!(variants.map { |variant|
    { account_id: account.id, workspace_id: workspace.id, creating_user_id: reader.id,
      conversation_turn_variant_id: variant.fetch("id"), status: "completed", approval_mode: "bypass",
      created_at: now, updated_at: now }
  }, returning: %w[id public_id]).to_a

  # Most history is derived work too, so the recursive predicate cannot appear
  # cheap merely because only the five chain rows carry sender stamps.
  ConversationTurn.where(id: turns[1...9_995].map { |turn| turn.fetch("id") }).update_all(
    sender_agent_loop_public_id: loops.first.fetch("public_id"), sender_task_key: "background")

  # A completed five-generation chain ends outside the root conversation.
  previous = loops.first.fetch("public_id")
  (9_995...10_000).each do |index|
    ConversationTurn.where(id: turns[index].fetch("id")).update_all(
      sender_agent_loop_public_id: previous, sender_task_key: "background")
    previous = loops[index].fetch("public_id")
  end
  ConversationInput.insert_all!(10_000.times.map { |index|
    { account_id: account.id, host_type: "Conversation", host_id: hosts[index / 1_000].id,
      queue_position: index % 1_000, kind: "message", speaker_actor_id: actor.id,
      authoring_user_id: reader.id, answering_user_id: reader.id, origin: "agent",
      sender_agent_loop_public_id: index % 2_000 == 0 ? previous : loops.first.fetch("public_id"),
      sender_task_key: "background", created_at: now, updated_at: now }
  })
  %w[agent_loops conversation_turns conversation_turn_variants conversation_inputs].each do |table|
    connection.execute("ANALYZE #{table}")
  end

  reads = capture.call do
    pass = AgentLoops::Spawn::Relay.call(children_done: true, delegations_done: true, budget: 200)
    raise "unexpected recovery source cardinality" unless pass[:scanned] == 400
  end
  explain.call("bounded input source frontier", reads.find { |sql| sql.start_with?('SELECT "conversation_inputs"."id"') })
  explain.call("bounded variant source frontier", reads.find { |sql| sql.start_with?('SELECT "conversation_turn_variants"."id"') })

  # The hint's owner is sparse among retained requests. Capture its actual
  # production selectors, then compare the old indexes in a rollback-only
  # savepoint; the global recovery frontier needs its id-leading index too.
  hint_reads = capture.call do
    AgentLoops::SourceWork::Recovery.call(source_loop_public_id: previous)
    AgentLoops::SourceWork::Recovery.call(source_loop_public_id: loops[9_997].fetch("public_id"))
  end
  hint_queries = {
    "input hint (5/10,000 scattered requests)" => hint_reads.find { |sql|
      sql.start_with?('SELECT "conversation_inputs"."id"') && sql.include?(previous)
    },
    "turn hint (1/10,000 retained requests)" => hint_reads.find { |sql|
      sql.start_with?('SELECT "conversation_turns"."id"') && sql.include?(loops[9_997].fetch("public_id"))
    },
  }
  hint_queries.each { |label, sql| explain.call("source-leading index: #{label}", sql) }
  ApplicationRecord.transaction(requires_new: true) do
    connection.remove_index(:conversation_inputs, name: "index_conversation_inputs_on_source_work")
    connection.remove_index(:conversation_turns, name: "index_conversation_turns_on_source_work")
    hint_queries.each { |label, sql| explain.call("existing indexes only: #{label}", sql) }
    raise ActiveRecord::Rollback
  end

  cuts = capture.call do
    ApplicationRecord.transaction(requires_new: true) do
      result = Conversations::Turns::Cancel.stop_now(hosts.first)
      raise "stop refused" unless result.accepted?

      raise ActiveRecord::Rollback
    end
  end
  explain.call("conversation owner set cut", cuts.find { |sql| sql.start_with?('UPDATE "agent_loops"') })
  leaf = AgentLoop.find(loops.last.fetch("id"))
  ancestry = capture.call do
    raise "completed ancestor stop was missed" unless AgentLoops::SourceWork.stopped_source?(leaf)
  end
  explain.call("effective completed ancestor stop", ancestry.find { |sql| sql.start_with?("WITH RECURSIVE ownership") })
  puts "Verified 10,000 owners; capped 200/10,000 input + variant candidates (9,000 failed); sparse owner hints; 1,000-loop cut; five-generation stop."
  raise ActiveRecord::Rollback
end
puts "Synthetic rows rolled back."
