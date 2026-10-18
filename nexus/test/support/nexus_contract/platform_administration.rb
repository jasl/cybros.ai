module Nexus
  module Contract
    class << self
      private

        def platform_budgets
          measured_at = Time.iso8601("2026-10-15T01:00:00Z")
          budget = UsageBudget.new(
              public_id: "01900000-0000-7000-8000-000000000050", user_public_id: "01900000-0000-7000-8000-000000000001",
              user_kind: "human",
              credited_amount: BigDecimal("10.000000000000000001"), debited_amount: BigDecimal("0.125"),
              account: Account.new(cost_unit: "fixture-unit"), starts_at: Time.iso8601("2026-10-15T00:00:00Z"),
              expires_at: nil, revoked_at: nil
            )
          entry = UsageBudgetEntry.new(
            public_id: "01900000-0000-7000-8000-000000000051", actor_public_id: budget.user_public_id,
            cost_unit: "fixture-unit", entry_sequence: 2, kind: "credit_adjustment",
            amount: BigDecimal("0.000000000000000001"), reason: "Fixture adjustment",
            operation_key: "fixture-budget-adjustment", created_at: Time.iso8601("2026-10-15T01:00:00Z")
          )
          row = stringify_keys(UsageBudgets::Projection.budget(budget, at: measured_at))
          adjustment = stringify_keys(UsageBudgets::Projection.adjustment_entry(entry))
          list = { "user_public_id" => budget.user_public_id, "user_kind" => budget.user_kind,
            "cost_unit" => "fixture-unit", "measured_at" => measured_at, "current_budget" => row,
            "budgets" => [row], "pagination" => { "next_after" => nil } }
          {
            "valid_list_fixture" => list,
            "valid_show_fixture" => { "budget" => row, "measured_at" => measured_at },
            "valid_entries_fixture" => { "entries" => [stringify_keys(UsageBudgets::Projection.entry(entry))],
              "pagination" => { "next_after" => nil } },
            "valid_uncapped_fixture" => list.merge("current_budget" => nil, "budgets" => []),
            "valid_open_fixture" => { "budget" => row },
            "valid_adjust_fixture" => { "budget" => row, "entry" => adjustment },
            "valid_revoke_fixture" => { "budget" => row.merge("revoked_at" => "2026-10-15T02:00:00Z",
              "revoked_by_public_id" => budget.user_public_id, "revoke_reason" => "Window closed", "usable" => false) },
            "unknown_entry_kind_fixture" => { "budget" => row, "entry" => adjustment.merge("kind" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_kind_behavior" => "carry_unknown", "amount_encoding" => "decimal_string",
            "idempotency_header" => "Idempotency-Key", "open_success_status" => 201,
          }
        end

        def platform_usage
          counters = ModelUsageTimeBucket::COUNTER_COLUMNS.index_with(0).merge(
            request_count: 3, input_tokens: 900, output_tokens: 120, total_tokens: 1020,
            cost_amount: BigDecimal("0.040500000000000001"), cost_known_request_count: 3
          )
          totals = ModelUsageRollups::UsageReport.allocate.send(:render_counters, counters)
          report = { "unit" => "hour", "series" => [totals.merge("bucket_start_at" => "2026-10-15T00:00:00Z")],
            "totals" => totals }
          {
            "units" => ModelUsageRollups::UsageReport::UNITS,
            "filters" => ModelUsageRollups::UsageReport::FILTER_COLUMNS,
            "valid_report_fixture" => { "report" => report },
            "unknown_unit_fixture" => { "report" => report.merge("unit" => UNKNOWN_VALUE_FIXTURE) },
            "unknown_unit_behavior" => "carry_unknown", "amount_encoding" => "decimal_string",
          }
        end
    end
  end
end
