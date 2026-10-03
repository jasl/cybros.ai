class WorkspaceCommandReceipt
  # The create-idempotency wrapper: replay or mismatch on a current
  # receipt, else run and commit the receipt with the effect.
  class Idempotent
    Success = Data.define(:status, :body, :workspace)
    Result = Data.define(:outcome, :response, :receipt, :refusal) do
      class << self
        def executed(response)
          new(outcome: :executed, response: response, receipt: nil, refusal: nil)
        end

        def replayed(receipt)
          new(outcome: :replayed, response: nil, receipt: receipt, refusal: nil)
        end

        def mismatched(receipt)
          new(outcome: :mismatched, response: nil, receipt: receipt, refusal: nil)
        end

        def refused(refusal)
          new(outcome: :refused, response: nil, receipt: nil, refusal: refusal)
        end
      end
    end

    class << self
      def call(**scope, &command)
        new(**scope).call(&command)
      end
    end

    def initialize(account:, acting_user:, operation:, idempotency_key:, request_digest:,
                   workspace: nil)
      @account = account
      @acting_user = acting_user
      @operation = operation.to_s
      @idempotency_key = idempotency_key
      @request_digest = request_digest
      @workspace = workspace
    end

    def call(&command)
      existing = current_receipt
      if existing
        settled(existing)
      else
        execute(&command)
      end
    end

    private

      def execute
        response = nil
        refusal = nil
        ApplicationRecord.transaction do
          product = yield
          case product
          when Success
            response = product
            persist_receipt(product)
          else
            refusal = product
          end
        end

        if refusal
          # A same-key winner may have committed while this was blocked on
          # the domain's locks; the refusal then settles on the winner's receipt.
          winner = current_receipt
          winner ? settled(winner) : Result.refused(refusal)
        else
          Result.executed(response)
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent first attempt won the unique receipt scope; this
        # loser's whole effect rolled back with the transaction above, so it
        # settles on the winner exactly like a retry would.
        winner = current_receipt
        raise unless winner

        settled(winner)
      end

      def settled(receipt)
        if receipt.request_digest == @request_digest
          Result.replayed(receipt)
        else
          Result.mismatched(receipt)
        end
      end

      # PostgreSQL evaluates the coarse cutoff; an expired row stops
      # reserving the key here, and the reaper only bounds storage.
      def current_receipt
        lookup_scope.older_than(WorkspaceCommandReceipt::RETENTION).delete_all
        lookup_scope.first
      end

      def lookup_scope
        scope = WorkspaceCommandReceipt.where(
          acting_user_id: @acting_user.id,
          operation: @operation,
          idempotency_key: @idempotency_key,
        )
        case @operation
        when "workspace_create"
          scope.where(account_id: @account.id)
        when "store_entry_create"
          scope.where(workspace_id: @workspace.id)
        else
          raise ArgumentError, "unknown receipt operation: #{@operation}"
        end
      end

      def persist_receipt(product)
        WorkspaceCommandReceipt.create!(
          account: @account,
          workspace: product.workspace,
          acting_user: @acting_user,
          operation: @operation,
          idempotency_key: @idempotency_key,
          request_digest: @request_digest,
          response_status: product.status,
          response_body: product.body,
        )
      end
  end
end
