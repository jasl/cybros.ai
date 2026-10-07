class ConversationCommandReceipt
  # The conversation plane's create-idempotency wrapper: replay or
  # mismatch on a current receipt, else run and commit the receipt with the
  # effect. A wrapped command raising Rollback must use `requires_new: true`.
  class Idempotent
    Success = Data.define(:status, :body, :host)
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

    def initialize(account:, workspace:, acting_user:, operation:, idempotency_key:,
                   request_digest:, host: nil)
      @account = account
      @workspace = workspace
      @acting_user = acting_user
      @operation = operation.to_s
      @idempotency_key = idempotency_key
      @request_digest = request_digest
      @host = host
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
          # A same-key winner may have committed while this command was
          # blocked on the domain's own locks; the refusal then settles on
          # the winner's receipt exactly like a retry would.
          winner = current_receipt
          winner ? settled(winner) : Result.refused(refusal)
        else
          Result.executed(response)
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent first attempt won the unique receipt scope; this
        # loser's whole effect rolled back with the transaction above, so it
        # settles on the winner exactly like a retry would. Rails leaves a
        # record saved inside a rolled-back transaction holding the unsaved
        # values, and the command saved its host (the door notes activity):
        # a caller that runs its next command on the same object — a mail
        # pass over several tips — would lock it and raise. Read it back.
        @host&.reload
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

      # Rails persists acceptance in created_at; PostgreSQL evaluates the
      # coarse 24-hour cutoff. An expired row stops reserving the key here,
      # while the hourly reaper only bounds storage.
      def current_receipt
        lookup_scope.older_than(ConversationCommandReceipt::RETENTION).delete_all
        lookup_scope.first
      end

      # conversation_create keys on the workspace; the host-anchored
      # operations key on their host, so one key never replays across hosts
      # (the digest already fences across operations).
      def lookup_scope
        scope = ConversationCommandReceipt.where(
          acting_user_id: @acting_user.id,
          operation: @operation,
          idempotency_key: @idempotency_key,
        )
        case @operation
        when "conversation_create"
          scope.where(workspace_id: @workspace.id)
        when "input_create", "fork", "regeneration", "store_entry_create", "schedule_create"
          raise ArgumentError, "#{@operation} needs its host" if @host.nil?

          scope.where(host: @host)
        else
          raise ArgumentError, "unknown receipt operation: #{@operation}"
        end
      end

      # Anchored on the operation's host, which the lookup scope keys on;
      # conversation_create has none yet, so the created row fills it.
      def persist_receipt(product)
        ConversationCommandReceipt.create!(
          account: @account,
          workspace: @workspace,
          host: @host || product.host,
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
