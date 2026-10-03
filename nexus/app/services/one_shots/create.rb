module OneShots
  # The atomic OneShot create. The order is the contract: authority generation first so a
  # cut during preparation is visible, receipt lookup before preparation, then
  # upload pinning, admission and persistence in one transaction.
  class Create
    Command = Data.define(
      :workspace, :creating_user, :workload, :submitted, :configuration,
      :input, :upload_public_ids, :billing_subject, :idempotency_key
    )

    # `created` and `replayed` are one answer reached two ways; a mismatch
    # or refusal names no target, since the caller may not learn what the key points at.
    Result = Data.define(:outcome, :accepted, :refusal) do
      class << self
        def created(accepted) = new(outcome: :created, accepted: accepted, refusal: nil)
        def replayed(accepted) = new(outcome: :replayed, accepted: accepted, refusal: nil)
        def idempotency_mismatch = new(outcome: :idempotency_mismatch, accepted: nil, refusal: nil)
        def refused(refusal) = new(outcome: :refused, accepted: nil, refusal: refusal)
      end

      def created? = outcome == :created
      def replayed? = outcome == :replayed
      def accepted? = !accepted.nil?
    end

    BODY_ROLE = "input".freeze
    # One refusal for every way the admission recheck can fail. Which authority
    # moved is not the caller's to learn, and naming it would make this a
    # membership oracle.
    NOT_AUTHORIZED = :not_authorized
    # The key exists under a different owner: safe to name, since the
    # caller supplied the key and learns nothing new.
    BILLING_SUBJECT_NOT_OWNED = :billing_subject_not_owned

    def self.call(...) = new(...).call

    def initialize(command:, port: ModelSelection::UNAVAILABLE_PORT)
      @command = command
      @port = port
    end

    def call
      @authority_generation = @command.creating_user.authority_generation
      # Coerced once, before the digest and before the boundary, so the
      # identity of a command is the command the grammar will actually judge —
      # a field it drops must not be able to turn a retry into a conflict.
      @input = CoerceTextMessages.call(@command.input)
      @configuration = CoerceConfiguration.call(@command.configuration)
      @upload_public_ids = Array(@command.upload_public_ids).map do |public_id|
        ContentUpload.canonical_public_id(public_id)
      end

      envelope = build_envelope
      return Result.refused(envelope.refusal) unless envelope.accepted?

      # The NORMALIZED envelope is what the digest was taken over, so the
      # billing key verified below is byte-identical to the digested one.
      @envelope = envelope.envelope
      @digest = envelope.request_digest
      existing = current_receipt
      return settled(existing) if existing

      commit
    end

    private

      def account = @command.workspace.account

      def build_envelope
        RequestEnvelope.build(
          workload: @command.workload,
          model_selection: @command.submitted.to_h,
          configuration: @configuration,
          input: @input,
          upload_public_ids: @upload_public_ids,
          billing_subject: @command.billing_subject
        )
      end

      # Everything expensive, and nothing durable. Selection is asked exactly
      # once here; the persisted mirrors are all derived from that one answer
      # rather than resolved again anywhere downstream. Called INSIDE the lock
      # section (the same order as the conversation input door): `lock: true`
      # pins the resolved uploads `FOR KEY SHARE` for the transaction about to
      # bind them, so the orphan reaper cannot destroy one between this read
      # and the join. Outside it the bind would meet a vanished row as an
      # `InvalidForeignKey`, a 500 where a 422 was promised.
      def prepare
        PrepareInput.call(
          account: account,
          creating_user: @command.creating_user,
          workload: @command.workload,
          submitted: @command.submitted,
          configuration: @configuration,
          input: @input,
          upload_public_ids: @upload_public_ids,
          port: @port,
          lock: true
        )
      end

      # The lock section. `requires_new` so that a refusal found after the
      # owner row exists takes its own writes back even if a caller wrapped
      # this command in a transaction of their own.
      def commit
        result = nil
        ApplicationRecord.transaction(requires_new: true) do
          workspace = @command.workspace.lock!
          creator = @command.creating_user.lock!
          # Agent, then steward, kept on the association so the recheck reads
          # the locked row rather than a separate unlocked one.
          creator.steward&.lock! if creator.agent_member?

          prepared = prepare
          result = if prepared.accepted?
            admit(prepared, workspace, creator)
          else
            Result.refused(prepared.refusal)
          end
          raise ActiveRecord::Rollback unless result.created?
        end

        result
      rescue ActiveRecord::RecordNotUnique
        # A concurrent first attempt won the scoped key; this loser's rows all
        # rolled back with the transaction, so it settles on the winner's
        # receipt exactly as a retry would.
        winner = current_receipt
        raise unless winner

        settled(winner)
      end

      def admit(prepared, workspace, creator)
        return Result.refused(NOT_AUTHORIZED) unless admissible?(workspace, creator)

        attribution = verified_billing_attribution(workspace.account, creator)
        return Result.refused(BILLING_SUBJECT_NOT_OWNED) if attribution.nil?

        insert(prepared, workspace, creator, attribution)
      end

      # The live truth from the rows now held: create-first is visible to a
      # later cut, cut-first rejects the stale create.
      def admissible?(workspace, creator)
        # Uncached: the query cache would answer from the snapshot taken
        # before these locks, the one moment this recheck must not read.
        ApplicationRecord.uncached do
          workspace.data_writable_by?(creator) &&
            creator.authority_generation == @authority_generation
        end
      end

      # Nil ONLY for a key owned by somebody else; an absent subject is the
      # empty attribution, which is a perfectly good answer.
      def verified_billing_attribution(account, creator)
        key = @envelope.fetch("billing_subject")
        return {} if key.nil?

        result = BillingSubjects::CreateOrVerify.call(
          account: account, acting_user: creator, key: key
        )
        return nil unless result.verified?

        {
          billing_subject_key: result.billing_subject.key,
          billing_subject_public_id: result.billing_subject.public_id,
        }
      end

      def insert(prepared, workspace, creator, attribution)
        one_shot = OneShot.create!(
          workspace: workspace, creating_user: creator,
          workload: prepared.selection.workload,
          **attribution
        )

        input_body = ContentBodies::Replace.call(
          owner: one_shot, role: BODY_ROLE,
          entries: input_entries(prepared),
          uploads: prepared.normalized.uploads,
          seal: true
        )
        return Result.refused(input_body.refusal) unless input_body.accepted?

        selection = prepared.selection
        invocation = ModelInvocation.create!(
          one_shot: one_shot,
          provider_id: selection.provider_id,
          model_ref: selection.model_ref,
          reasoning_effort: selection.reasoning.effort,
          request_options: selection.generation_config.to_h.merge(
            Nexus::PromptCache::RequestKind::FACT => Nexus::PromptCache::RequestKind.stamp("one_shot")
          ),
          admission_deadline_seconds:
            selection.execution_profile.total_execution_deadline_seconds
        )
        ContentBodies::CloneSealed.call(
          source: input_body.body, owner: invocation, role: "request"
        )

        receipt = OneShotCreateReceipt.create!(
          one_shot: one_shot, idempotency_key: @command.idempotency_key,
          request_digest: @digest
        )

        Result.created(receipt.result)
      end

      def input_entries(prepared)
        normalized = prepared.normalized
        if prepared.selection.workload == "image_generation"
          Nexus::InputEntries.for_image(
            normalized.value, upload_public_ids: normalized.uploads.map(&:public_id)
          )
        else
          Nexus::InputEntries.for(normalized.value)
        end
      end

      # PostgreSQL evaluates the cutoff, so no application clock decides
      # whether a key is still reserved; the reaper only bounds storage.
      def current_receipt
        expired_scope.delete_all
        receipt_scope.first
      end

      # The workload is in the digest, not the scope, so a same-key
      # different-workload retry is a mismatch rather than a second billable create.
      def receipt_scope
        OneShotCreateReceipt.where(
          account_id: @command.workspace.account_id,
          workspace_id: @command.workspace.id,
          acting_user_id: @command.creating_user.id,
          idempotency_key: @command.idempotency_key
        )
      end

      def expired_scope
        receipt_scope.older_than(OneShotCreateReceipt::RETENTION)
      end

      def settled(receipt)
        if receipt.request_digest == @digest
          Result.replayed(receipt.result)
        else
          Result.idempotency_mismatch
        end
      end
  end
end
