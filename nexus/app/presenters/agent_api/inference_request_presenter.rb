module AgentAPI
  # Basic for lists, Full for singular responses. No row ids, frozen
  # selection jsonb or invocation anatomy; the model identity nests under
  # `model` and the derived status is the InferenceRequest's one public state. Both
  # read the run's LATEST execution — the creator's fallback's, once a
  # declined first one ran again on it.
  class InferenceRequestPresenter
    EMBEDDING = "embedding".freeze

    class << self
      def basic(inference_request)
        invocation = inference_request.model_invocation
        {
          public_id: inference_request.public_id,
          workload: inference_request.workload,
          status: inference_request.status,
          model: {
            provider_id: invocation.provider_id,
            model_ref: invocation.model_ref,
            reasoning_effort: invocation.reasoning_effort, reasoning_enabled: invocation.reasoning_enabled,
          },
          billing_subject: inference_request.billing_subject_key,
          created_at: inference_request.created_at,
          updated_at: inference_request.updated_at,
        }
      end

      def full(inference_request)
        projection = basic(inference_request).merge(
          # Cumulative across the whole attempt history, retries included, where
          # `result.usage` is the terminal attempt's own; zero requests is a
          # true statement, so it is always present.
          usage_summary: ModelUsageSummary.public_projection(
            subject_kind: ModelUsageSummary::SUBJECT_KINDS.fetch(:inference_request),
            subject_id: inference_request.id
          )
        )
        envelope = result(inference_request, inference_request.model_invocation)
        envelope.nil? ? projection : projection.merge(result: envelope)
      end

      # `has_many_attached` emits no ORDER BY and the provider's image index
      # lives only in the blob filename, so attachment-id order is arrival
      # order. Public because the file route addresses by this ordinal.
      def output_files(inference_request)
        invocation = inference_request.model_invocation
        return [] if invocation.nil?

        output_attachments(invocation)
      end

      private

        # The complete terminal result; the event stream carries only a wake.
        # Present only once terminal — the contract keys terminality on its presence.
        def result(inference_request, invocation)
          return nil if invocation.nil?
          return nil unless inference_request.terminal?

          receipt = latest_attempt_receipt(invocation)
          {
            status: inference_request.status,
            # A sibling of status, never a member of `error`: a cut-off answer
            # is a success with a caveat, and a declined one a failure whose
            # code is in `error`. Absent on a clean finish.
            finish_quality: invocation.finish_quality,
            # The provider's word beside a declined finish; absent when it
            # named none.
            refusal_category: invocation.refusal_category,
            output_text: output_text(inference_request, invocation),
            embeddings: embeddings(inference_request, invocation),
            usage: UsageRecords::PublicUsage.render(receipt),
            timing: UsageRecords::PublicUsage.timing(receipt),
            error: error(invocation, receipt),
            reasoning: reasoning(invocation),
            output_files: output_file_projections(invocation),
            model_change: model_change(inference_request, invocation),
          }.compact
        end

        # What this execution replaced when the creator's declared fallback
        # ran a declined or overloaded run again — `{from, to, reason,
        # category?}`, the switch's own narration — absent on a run that
        # never moved.
        def model_change(inference_request, invocation)
          replaced = inference_request.model_invocations.where.not(id: invocation.id).order(:id).last
          return nil if replaced.nil?

          AgentRuns::ModelFallback::Candidate.new(
            provider_id: invocation.provider_id, model_ref: invocation.model_ref,
            reasoning_effort: invocation.reasoning_effort, reasoning_enabled: invocation.reasoning_enabled, reason: AgentRuns::ModelFallback.reason_of(replaced),
            category: replaced.refusal_category
          ).narration("#{replaced.provider_id}/#{replaced.model_ref}").fetch("model_change")
        end

        def output_attachments(invocation)
          invocation.output_files_attachments.includes(:blob).order(:id).to_a
        end

        # Absent for every workload that produces no files, which is what keeps
        # a text caller from having to know this member exists.
        def output_file_projections(invocation)
          attachments = output_attachments(invocation)
          return nil if attachments.empty?

          attachments.each_with_index.map do |attachment, index|
            blob = attachment.blob
            {
              index: index,
              filename: blob.filename.to_s,
              content_type: blob.content_type,
              byte_size: blob.byte_size,
            }
          end
        end

        # Absent on the embedding workload: its answer is the vectors below,
        # never a JSON document a caller has to parse out of the prose slot.
        def output_text(inference_request, invocation)
          return nil if inference_request.workload == EMBEDDING

          response_text(invocation)
        end

        # THE TYPED NON-TEXT RESULT: the response body holds the
        # gem-normalized document (`ApplyResult#embedding_payload`), read once
        # here and rendered `[{index, vector}]` in the provider's order.
        def embeddings(inference_request, invocation)
          return nil unless inference_request.workload == EMBEDDING

          text = response_text(invocation)
          return nil if text.nil?

          JSON.parse(text).fetch("embeddings").map do |row|
            { index: row.fetch("index"), vector: row.fetch("embedding") }
          end
        end

        def response_text(invocation)
          return nil unless invocation.status == "completed"

          invocation.content_bodies.find_by(role: "response")&.effective_text.presence
        end

        def error(invocation, receipt)
          ModelInvocations::PublicError.render(invocation, receipt)
        end

        def reasoning(invocation)
          body = invocation.content_bodies.find_by(role: "reasoning")
          return nil if body.nil?

          { available: true, text: body.effective_text.presence }.compact
        end

        def latest_attempt_receipt(invocation)
          UsageRecord.for_latest_attempt(invocation)
        end
    end
  end
end
