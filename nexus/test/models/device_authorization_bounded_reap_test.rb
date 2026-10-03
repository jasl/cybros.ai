require "test_helper"

# DeviceAuthorization cleanup must bound both discovery and application. A
# LIMIT nested inside UPDATE/DELETE is insufficient: PostgreSQL may scan the
# complete retained set before it discovers that limit.
class DeviceAuthorizationBoundedReapTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @sequence = 10_000_000
  end

  test "expiry and terminal retention share one source-row budget without starvation" do
    now = Time.current
    due = insert_authorizations(3, status: "pending", expires_at: now - 1.minute,
      updated_at: now)
    old_terminal = insert_authorizations(3, status: "canceled", expires_at: now - 1.day,
      updated_at: now - DeviceAuthorization::TERMINAL_RETENTION - 1.minute)
    future = insert_authorizations(1, status: "pending", expires_at: now + 1.hour,
      updated_at: now)
    fresh_terminal = insert_authorizations(1, status: "consumed", expires_at: now - 1.day,
      updated_at: now)

    first = DeviceAuthorization.reap(now: now, batch_size: 4)

    assert_equal 2, first[:expired]
    assert_equal 2, first[:deleted]
    assert_equal 4, first[:scanned]
    assert first.more?

    second = DeviceAuthorization.reap(now: now, batch_size: 4)

    assert_equal 1, second[:expired]
    assert_equal 1, second[:deleted]
    assert_equal 2, second[:scanned]
    assert_not second.more?
    assert due.all? { |id| DeviceAuthorization.find(id).expired? }
    assert old_terminal.none? { |id| DeviceAuthorization.exists?(id) }
    assert DeviceAuthorization.exists?(future.first)
    assert DeviceAuthorization.exists?(fresh_terminal.first)
  end

  test "both production phases use their due indexes and apply only by materialized ids" do
    now = Time.current
    insert_authorizations(6_000, status: "pending", expires_at: now + 1.day,
      updated_at: now)
    insert_authorizations(400, status: "pending", expires_at: now - 1.day,
      updated_at: now)
    insert_authorizations(6_000, status: "canceled", expires_at: now - 1.day,
      updated_at: now)
    insert_authorizations(400, status: "canceled", expires_at: now - 1.day,
      updated_at: now - DeviceAuthorization::TERMINAL_RETENTION - 1.day)
    ApplicationRecord.lease_connection.execute("ANALYZE device_authorizations")

    statements = capture_reap_statements do
      result = DeviceAuthorization.reap(now: now, batch_size: 100)
      assert_equal 50, result[:expired]
      assert_equal 50, result[:deleted]
      assert_equal 100, result[:scanned]
      assert result.more?
    end

    expiry_source = explain(*statements.fetch(:expiry_source))
    terminal_source = explain(*statements.fetch(:terminal_source))
    expiry_apply = explain(*statements.fetch(:expiry_apply))
    terminal_apply = explain(*statements.fetch(:terminal_apply))

    assert_match(/Limit/, expiry_source)
    assert_match(/index_device_authorizations_on_live_expiry/, expiry_source)
    assert_no_match(/Seq Scan on device_authorizations(?:\s|$)/, expiry_source)
    assert_match(/Limit/, terminal_source)
    assert_match(/index_device_authorizations_on_terminal_retention/, terminal_source)
    assert_no_match(/Seq Scan on device_authorizations(?:\s|$)/, terminal_source)

    [expiry_apply, terminal_apply].each do |plan|
      assert_match(/device_authorizations_pkey/, plan)
      assert_no_match(/Seq Scan on device_authorizations(?:\s|$)/, plan)
      assert_no_match(/Hash Semi Join/, plan)
    end
  end

  private

    def insert_authorizations(count, status:, expires_at:, updated_at:)
      ids = []
      count.times.each_slice(1_000) do |slice|
        rows = slice.map do
          @sequence += 1
          {
            account_id: @account.id,
            client_id: OAuth::DEVICE_CLIENT_ID,
            agent_identifier: "bounded-reap",
            agent_display_name: "Bounded reap",
            requested_executor_display_name: "Bounded executor",
            device_code_lookup_id: "plan-#{@sequence.to_s(36)}",
            device_code_digest: "digest",
            user_code: @sequence.to_s.rjust(8, "0"),
            status: status,
            expires_at: expires_at,
            created_at: updated_at,
            updated_at: updated_at,
          }
        end
        ids.concat(DeviceAuthorization.insert_all!(rows, returning: %w[id]).rows.flatten)
      end
      ids
    end

    def capture_reap_statements
      statements = {}
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        next if payload[:name] == "SCHEMA" || payload[:cached]

        key = reap_statement_key(sql)
        statements[key] ||= [sql.dup, payload.fetch(:binds).dup] if key
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    def reap_statement_key(sql)
      if sql.start_with?('SELECT "device_authorizations"."id"')
        if sql.include?('ORDER BY "device_authorizations"."expires_at"')
          :expiry_source
        else
          :terminal_source
        end
      elsif sql.start_with?('UPDATE "device_authorizations"')
        :expiry_apply
      elsif sql.start_with?('DELETE FROM "device_authorizations"')
        :terminal_apply
      end
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
