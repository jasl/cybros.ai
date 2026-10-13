module UsageRecords
  # One receipt per started attempt on every disposition, idempotent by (invocation, ordinal).
  # Pricing happens here at settlement from the Account's effective catalog; money is recorded,
  # never invented.
  class Record
    def self.call(...) = new(...).call

    # A nil outcome is the evidence-dead receipt: everything is written as
    # unknown, and it is still a receipt because `usage_records` is the one
    # table reclamation spares. `invocation_locked` trusts ApplyResult's lock.
    def initialize(attempt:, outcome:, status:, error_code: nil, invocation_locked: false)
      @attempt = attempt
      @outcome = outcome
      @status = status
      @error_code = error_code
      @invocation = attempt.model_invocation
      @invocation_locked = invocation_locked
    end

    def call
      record = nil
      UsageRecord.transaction(requires_new: true) do
        # A late real result and the closer both write this attempt; the
        # invocation lock is their arbiter, the unique receipt alone is not.
        lock_invocation unless @invocation_locked
        @attempt.reload

        if @attempt.settlement_state == "pending"
          record = UsageRecord.create_or_find_by!(receipt_identity) do |receipt|
            receipt.assign_attributes(attributes)
          end
          # Only for the row that actually inserted, so two writers
          # converging on one attempt increment exactly once.
          if record.previously_new_record?
            ModelUsageSummary.increment_for_usage_record(
              record, subject_id: inference_request&.id
            )
          end
          # The persisted winner decides the Attempt edge: a late writer
          # never relabels an abandoned receipt, and the closer repairs rather than overwrites.
          @attempt.update!(settlement_state: settlement_state_for(record))
        else
          # A replay after either terminal settlement returns the immutable
          # winner. A state claiming completion without its receipt is durable
          # corruption and stays loud rather than manufacturing new evidence.
          record = UsageRecord.find_by!(receipt_identity)
          expected_state = settlement_state_for(record)
          if @attempt.settlement_state != expected_state
            @attempt.update!(settlement_state: expected_state)
          end
        end
        record
      end
      record
    end

    private

      def attributes
        {
          account: @invocation.account,
          idempotency_key: "#{@invocation.internal_creation_key}:#{@attempt.ordinal}",
          consumer_user_public_id: @attempt.consumer_public_id,
          payer_user_public_id: @attempt.payer_public_id,
          workspace_public_id: @invocation.workspace&.public_id,
          inference_request_public_id: inference_request&.public_id,
          conversation_public_id: @invocation.conversation&.public_id || @invocation.agent_run&.conversation_public_id,
          provider_id: @invocation.provider_id,
          catalog_model_ref: catalog_ref,
          wire_model_id: @outcome&.profile&.model_pin,
          provider_request_id: @outcome&.request_id,
          workload: @invocation.workload,
          purpose: @invocation.purpose,
          service_class: @invocation.service_class,
          admission_shape: @attempt.admission_shape,
          status: @status,
          error_code: @error_code,
          recorded_at: DatabaseClock.now,
          provider_usage: bounded_usage,
          duration_ms: @outcome&.timing&.duration_ms,
          time_to_first_token_ms: @outcome&.timing&.time_to_first_token_ms,
          # Receipts are immutable, so a purpose this reader has not learned
          # loses its attribution forever.
          billing_subject_key: billing_owner&.billing_subject_key,
          billing_subject_public_id: billing_owner&.billing_subject_public_id,
          **tokens.slice(:input_tokens, :output_tokens, :reasoning_tokens,
                         :cache_read_tokens, :cache_creation_tokens, :total_tokens),
          **money,
        }
      end

      def receipt_identity
        {
          account_id: @invocation.account_id,
          model_invocation_public_id: @invocation.public_id,
          attempt_ordinal: @attempt.ordinal,
        }
      end

      def lock_invocation
        locked = ModelInvocation
          .joins(:account)
          .where(id: @invocation.id)
          .lock("FOR UPDATE OF model_invocations")
          .pick("model_invocations.id", "accounts.cost_unit")
        raise ActiveRecord::RecordNotFound if locked.nil?

        @account_cost_unit = locked.last
      end

      def inference_request
        return @inference_request if defined?(@inference_request)

        @inference_request = @invocation.inference_request
      end

      def billing_owner
        inference_request || @invocation.conversation || @invocation.agent_run
      end

      def settlement_state_for(record)
        record.status == UsageRecord::ABANDONED ? "abandoned" : "settled"
      end

      # ---- money ------------------------------------------------------------

      def money
        case @attempt.admission_shape
        when "unmetered"
          return { unit_pricing: nil, cost_amount: nil, cost_unit: nil }
        when "admitted_free"
          return {
            unit_pricing: nil,
            cost_amount: BigDecimal(0),
            cost_unit: account_cost_unit,
          }
        else
          nil
        end

        # No evidence, no price: a cost from a count nobody reported would
        # be invented money.
        return absent_money if @outcome.nil?

        priced_money
      end

      # The rates being served now; a catalog that stopped answering prices
      # nothing, and unknown cost is never free (`Pricing.settles_money?`).
      def priced_money
        entry = catalog.models[catalog_ref]
        return absent_money if entry.nil?

        pricing = ModelCatalog::EffectivePricing.project(
          entry: entry, model_ref: catalog_ref,
          provider: catalog.providers[Nexus::ModelRef.parse(catalog_ref).provider_id],
          account_unit: account_cost_unit
        )
        return absent_money unless Pricing.settles_money?(pricing)

        {
          unit_pricing: pricing.rates.empty? ? nil : pricing.rates.transform_values(&:to_s),
          cost_amount: bounded_amount(settled_amount(pricing)),
          cost_unit: pricing.account_unit,
        }
      end

      def account_cost_unit
        return @account_cost_unit if defined?(@account_cost_unit)

        @account_cost_unit = @invocation.account.cost_unit
      end

      def absent_money = { unit_pricing: nil, cost_amount: nil, cost_unit: nil }

      # The column must never be the first to find an unbounded input:
      # numeric(38,18) overflows past every rescue.
      MAX_COST_AMOUNT = BigDecimal("1e20")

      # Compared on the value the CAST produces: the column rounds to scale
      # 18 first.
      def bounded_amount(amount)
        return nil if amount.nil?

        amount.round(18) < MAX_COST_AMOUNT ? amount : nil
      end

      # The provider's own bill under the reviewed contract keyed by the
      # profile settlement carries back, else the catalog formula over this
      # attempt's counts (`Pricing.amount`, the one precedence). The two
      # counts only the kernel measures are asked for lazily: the images a
      # delivered result carries, and the sealed input's characters.
      def settled_amount(pricing)
        Pricing.amount(
          usage: usage_hash, contract: pricing.native_cost_contracts[@outcome.profile.profile_id],
          account_unit: pricing.account_unit, adapter_profile: @outcome.profile.adapter_profile,
          tokens: tokens, rates: pricing.rates, tier_multipliers: pricing.tier_multipliers,
          images: -> { @outcome.result&.images&.size }, characters: -> { delivered_input_characters }
        )
      end

      # Speech bills per input character from our own sealed body, so it is
      # gated on delivery: a refused attempt was billed nothing, and pricing
      # our own input would charge once per retry.
      def delivered_input_characters
        return nil if @outcome.result.nil?

        payloads = ModelRequests::InputSource.accepted_entry_payloads(@invocation)
        texts = payloads.filter_map { |payload| payload["text"] }
        texts.empty? ? nil : texts.sum(&:length)
      end

      # ---- token normalization (`UsageRecords::Tokens`, the one reading) ---

      def tokens
        @tokens ||= Tokens.read(usage_hash, adapter_profile: @outcome&.profile&.adapter_profile)
      end

      # Speech is the one family whose result deliberately carries no usage —
      # the predecessor excluded it from usage payloads for the same wire
      # fact — so the gate is the workload, never a respond_to? probe.
      def usage_hash
        # Nothing observed the wire; every reader below is a pure function
        # of this hash, so emptying it records unknown rather than zero.
        return @usage_hash = {} if @outcome.nil?

        @usage_hash ||= begin
          usage =
            if @invocation.workload == "speech_generation"
              nil
            else
              @outcome&.result&.usage
            end
          usage = failed_usage if usage.nil?
          storable_decimals(Hash(usage))
        rescue TypeError
          {}
        end
      end

      # A decimal the wire wrote exactly, kept exactly: canonical JSON has
      # no exponent-free form for `5.4e-7`, so it rides as a plain-notation
      # string both readers accept.
      def storable_decimals(value)
        case value
        when BigDecimal then value.to_s("F")
        when Hash then value.transform_values { storable_decimals(_1) }
        when Array then value.map { storable_decimals(_1) }
        else value
        end
      end

      # A provider that charged and then failed says so in its typed error:
      # the response.failed terminal carries usage, and it is the one thing
      # that distinguishes a billed failure from a refused request.
      def failed_usage
        case @outcome.error
        when SimpleInference::Protocols::OpenAIResponses::ResponseFailedError
          @outcome.error.usage
        else
          nil
        end
      end

      # Bounded raw evidence: the wire object as reported, capped so a
      # hostile provider cannot make a receipt row unbounded.
      def bounded_usage
        return nil if usage_hash.empty?
        return nil unless Nexus::SizeBounds.json_within?(:workspace_metadata_bound, usage_hash)

        usage_hash
      rescue Nexus::CanonicalJson::UnsupportedValue, Nexus::CanonicalJson::UnsupportedNumber,
             Nexus::CanonicalJson::UnsupportedText
        nil
      end

      def catalog_ref = "#{@invocation.provider_id}/#{@invocation.model_ref}"

      def catalog
        @catalog ||= ModelSelection::Resolver.effective_provider_catalog(
          @invocation.account, ModelCatalog.current, @invocation.provider_id
        )
      end
  end
end
