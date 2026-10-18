require "test_helper"
require "zlib"

class AgentAPI::ConversationExportTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
  end

  test "construction and an unconsumed close acquire no compression or database resource" do
    queries = []
    subscription = ->(*, payload) { queries << payload.fetch(:sql) }
    Zlib::Deflate.stub(:new, ->(*) { flunk "construction cannot open a compressor" }) do
      ActiveSupport::Notifications.subscribed(subscription, "sql.active_record") do
        export.close
      end
    end
    assert_empty queries
  end

  test "disconnect closes the compressor and leaves an incomplete document without an end record" do
    compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16)
    bytes = +"".b

    Zlib::Deflate.stub(:new, compressor) do
      assert_raises(IOError) do
        export.each do |chunk|
          bytes << chunk
          raise IOError, "reader disconnected"
        end
      end
    end

    assert_predicate compressor, :closed?
    inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
    assert_not_includes inflater.inflate(bytes), '"type":"end"'
    assert_raises(Zlib::Error) { Zlib::GzipReader.wrap(StringIO.new(bytes), &:read) }
  ensure
    inflater&.close
  end

  test "a failed database projection closes compression without publishing successful completion" do
    compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16)
    bytes = +"".b
    Zlib::Deflate.stub(:new, compressor) do
      AgentAPI::ConversationPresenter.stub(:full, ->(*) { raise ActiveRecord::StatementInvalid, "read failed" }) do
        assert_raises(ActiveRecord::StatementInvalid) { export.each { |chunk| bytes << chunk } }
      end
    end
    assert_predicate compressor, :closed?
    inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
    assert_not_includes inflater.inflate(bytes), '"type":"end"'
    assert_raises(Zlib::Error) { Zlib::GzipReader.wrap(StringIO.new(bytes), &:read) }
  ensure
    inflater&.close
  end

  test "input paging freezes its immutable frontier despite queue reordering and later arrivals" do
    count = AgentAPI::ConversationExport::PAGE_SIZE + 1
    inputs = Array.new(count) { |index| queued_input(index) }
    appended = nil
    records = stream_records do |record|
      next unless record.fetch("type") == "input" && appended.nil?

      # Reordering can move a not-yet-visited row behind the current queue position.
      inputs.first.update!(queue_position: count + 1)
      inputs.last.update!(queue_position: 0)
      appended = queued_input(count)
    end

    emitted = records.select { |record| record.fetch("type") == "input" }.map { |record| record.fetch("input") }
    assert_equal inputs.map(&:public_id), emitted.pluck("public_id")
    assert_equal count, emitted.pluck("public_id").uniq.length
    assert_not_includes emitted.pluck("public_id"), appended.public_id
    assert_equal 0, emitted.last.fetch("queue_position")
    assert_equal count, records.last.fetch("counts").fetch("input")
  end

  test "retained steer entries span pages without loading a complete body or repeating positions" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human,
      turn_status: "completed", variant_status: "completed", run_status: "completed")
    count = AgentAPI::ConversationExport::PAGE_SIZE + 3
    payloads = Array.new(count) { |index| { "role" => "user", "parts" => [{ "type" => "text", "text" => "steer #{index}" }] } }
    body = ContentBodies::Replace.call(owner: seam.variant, role: "steers", entries: payloads, seal: true)
    assert_predicate body, :accepted?, body.refusal.inspect
    loads = []
    subscriber = ->(*, payload) do
      loads << payload.fetch(:record_count) if payload.fetch(:class_name) == "ContentBodyEntry"
    end
    records = ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") { stream_records }

    steers = records.select { |record| record.fetch("type") == "steer" }
    assert_equal (0...count).to_a, steers.pluck("position")
    assert_equal payloads, steers.map { |record| record.fetch("steer") }
    assert steers.all? { |record| record.fetch("variant_public_id") == seam.variant.public_id }
    assert_operator loads.max, :<=, AgentAPI::ConversationExport::PAGE_SIZE
  end

  test "task and edge frontiers stay closed when later work is appended during consumption" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    first = model_task(seam.run, "first")
    second = model_task(seam.run, "second")
    seam.run.run_edges.create!(from_node: first, to_node: second, structural: true)
    appended = nil

    records = stream_records do |record|
      next unless record.fetch("type") == "task" && appended.nil?

      appended = model_task(seam.run, "later")
      seam.run.run_edges.create!(from_node: second, to_node: appended, structural: true)
    end

    assert_equal %w[first second], records.select { |record| record.fetch("type") == "task" }
      .map { |record| record.fetch("task").fetch("key") }
    assert_equal %w[first second], records.select { |record| record.fetch("type") == "graph_node" }
      .map { |record| record.fetch("node").fetch("key") }
    assert_equal [{ "from" => "first", "to" => "second", "structural" => true }],
      records.select { |record| record.fetch("type") == "graph_edge" }.map { |record| record.fetch("edge") }
  end

  test "usage pages stop on the Conversation receipt index despite unrelated retained history" do
    # A fresh physical layout prevents rolled-back receipt fixtures from skewing the planner.
    ApplicationRecord.lease_connection.execute("TRUNCATE TABLE usage_records")
    unrelated = SecureRandom.uuid_v7
    seed_receipts(10_000, conversation_public_id: unrelated, prefix: "other")
    count = AgentAPI::ConversationExport::PAGE_SIZE + 3
    seed_receipts(count, conversation_public_id: @conversation.public_id, prefix: "export")
    ApplicationRecord.lease_connection.execute("ANALYZE usage_records")
    expected = UsageRecord.where(conversation_public_id: @conversation.public_id).order(:id).pluck(:public_id)
    queries = []
    subscriber = ->(*, payload) do
      sql = payload.fetch(:sql)
      if sql.start_with?('SELECT "usage_records".*') && sql.include?("LIMIT")
        queries << [sql, payload.fetch(:binds).dup]
      end
    end
    records = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { stream_records }

    assert_equal expected, records.select { |record| record.fetch("type") == "usage" }
      .map { |record| record.fetch("usage").fetch("usage_record_public_id") }
    assert_equal 2, queries.length
    sql, binds = queries.first
    plan = ApplicationRecord.lease_connection.select_values(
      "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
    ).join("\n")
    assert_match(/\ALimit\s/, plan)
    assert_match(/Index Scan using index_usage_records_on_conversation_history/, plan)
    assert_no_match(/Seq Scan|Bitmap|Sort|Rows Removed by Filter: [1-9]/, plan)
    assert_match(/actual [^\n]*rows=#{AgentAPI::ConversationExport::PAGE_SIZE}(?:\.0+)? loops=1/, plan)
  end

  private

    def export = AgentAPI::ConversationExport.new(conversation: @conversation, user: @human)

    def stream_records
      inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      pending = +""
      records = []
      export.each do |chunk|
        pending << inflater.inflate(chunk)
        while (newline = pending.index("\n"))
          record = JSON.parse(pending.slice!(0..newline))
          records << record
          yield record if block_given?
        end
      end
      assert_predicate inflater, :finished?
      assert_empty pending
      assert_equal "end", records.last.fetch("type")
      assert_equal records.pluck("type").tally, records.last.fetch("counts")
      records
    ensure
      inflater&.close
    end

    def queued_input(position)
      @conversation.inputs.create!(kind: "message", role: "user", origin: "person",
        authoring_user: @human, speaker: Speakers::Resolve.member(account: @account, user: @human),
        queue_position: position, delivery_mode: "queue", context_mode: "assembled")
    end

    def model_task(run, key)
      run.tasks.create!(type: Tasks::ModelTask.sti_name, node_key: key, authored_by: "author",
        provider_id: "dev", model_ref: "mock-text")
    end

    def seed_receipts(count, conversation_public_id:, prefix:)
      UsageRecord.insert_all!(Array.new(count) do |index|
        { account_id: @account.id, idempotency_key: "#{prefix}:#{index}",
          model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
          consumer_user_public_id: @human.public_id, payer_user_public_id: @human.public_id,
          conversation_public_id: conversation_public_id, workspace_public_id: @conversation.workspace.public_id,
          provider_id: "dev", catalog_model_ref: "dev/mock-text", wire_model_id: "mock-text",
          workload: "text_generation", purpose: "run", service_class: "interactive",
          admission_shape: "admitted_free", status: "succeeded", recorded_at: Time.current,
          cost_amount: BigDecimal("0"), input_tokens: 2, output_tokens: 3, total_tokens: 5 }
      end)
    end
end
