module CybrosAgent
  module Platform
    Budget = Data.define(:public_id, :user_public_id, :user_kind, :credited_amount, :debited_amount,
      :headroom, :cost_unit, :starts_at, :expires_at, :revoked_at, :revoked_by_public_id, :revoke_reason, :usable)
    BudgetEntry = Data.define(:sequence, :kind, :amount, :reason, :operation_key, :created_at)
    BudgetLedgerEntry = Data.define(:public_id, :sequence, :kind, :amount, :cost_unit, :actor_public_id, :reason, :created_at)
    BudgetAdjustment = Data.define(:budget, :entry)
    BudgetRead = Data.define(:budget, :measured_at)
    BudgetOverview = Data.define(:user_public_id, :user_kind, :cost_unit, :measured_at, :current_budget, :items, :next_after)

    module BudgetProjections
      include Api::WorkspaceProjections
      include Api::Fields

      SHAPES = {
        Budget => { public_id: :string, user_public_id: :string, user_kind: :string,
          credited_amount: :string, debited_amount: :string, headroom: :string, cost_unit: :string,
          starts_at: :string, expires_at: :nullable_string, revoked_at: :nullable_string,
          revoked_by_public_id: :nullable_string, revoke_reason: :nullable_string, usable: :boolean },
        BudgetEntry => { sequence: :integer, kind: :string, amount: :string, reason: :nullable_string,
          operation_key: :string, created_at: :string },
        BudgetLedgerEntry => { public_id: :string, sequence: :integer, kind: :string, amount: :string,
          cost_unit: :string, actor_public_id: :nullable_string, reason: :nullable_string, created_at: :string },
        BudgetAdjustment => { budget: [:shape, Budget], entry: [:shape, BudgetEntry] },
        BudgetRead => { budget: [:shape, Budget], measured_at: :string },
        BudgetOverview => { user_public_id: :string, user_kind: :string, cost_unit: :nullable_string,
          measured_at: :string, current_budget: [:optional_shape, Budget],
          items: [:shapes, Budget, "budgets"], next_after: [:nullable_string, "pagination", "next_after"] },
      }.freeze
    end

    # The member and Human self views expose only reads. Their resource handles
    # share the amount projection without acquiring a steward/admin command.
    class BudgetReads
      include BudgetProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      def list(after: nil, limit: nil, order: nil)
        shape(BudgetOverview, @dispatch.call(@path, params: query(after:, limit:, order:)))
      end

      def fetch(public_id)
        shape(BudgetRead, @dispatch.call(budget_path(public_id)))
      end

      def entries(public_id, after: nil, limit: nil, order: nil)
        page(BudgetLedgerEntry, @dispatch.call("#{budget_path(public_id)}/entries",
          params: query(after:, limit:, order:)), "entries")
      end

      private

        def budget_path(public_id) = "#{@path}/#{path_segment(public_id, "public_id")}"
    end

    class Budgets < BudgetReads
      # Amounts remain decimal strings. The server owns balances and authority;
      # a failed command is never automatically retried by this handle.
      def open(amount:, starts_at:, idempotency_key:, expires_at: omitted_field, reason: omitted_field)
        body = fields(amount:, starts_at:, expires_at:, reason:)
        shape(Budget, @dispatch.call(@path, method: :post, success: 201,
          body: { "budget" => body }, headers: operation_headers(idempotency_key)), "budget")
      end

      def adjust(public_id, kind:, amount:, idempotency_key:, reason: omitted_field)
        shape(BudgetAdjustment, @dispatch.call(budget_path(public_id), method: :patch,
          body: { "budget" => fields(kind:, amount:, reason:) }, headers: operation_headers(idempotency_key)))
      end

      def revoke(public_id, idempotency_key:, reason: omitted_field)
        shape(Budget, @dispatch.call("#{budget_path(public_id)}/revocation", method: :post,
          body: { "revocation" => fields(reason:) }, headers: operation_headers(idempotency_key)), "budget")
      end

      private

        def operation_headers(key) = { "Idempotency-Key" => required_string(key, "idempotency_key") }
    end
  end
end
