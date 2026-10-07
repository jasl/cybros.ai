module ModelInvocations
  # The one builder for the terminal replay items. The REST InferenceRequest is the
  # complete result; the stream narrates bounded facts and wakes a follower
  # to read that authority, never a second full-result projection.
  class TerminalEventItems
    PREVIEW_LENGTH = 1_000

    def self.call(...) = new(...).call

    # `model_change` is the switch a declined call's terminal led to
    # (`InferenceRequests::Fallback`), nil otherwise.
    def initialize(invocation:, model_change: nil)
      @invocation = invocation
      @model_change = model_change
    end

    # The run's status is the WORK's: this records the terminal it
    # describes, so a declined answer is the failed run it comes to — unless
    # the creator's fallback runs it again, when the run goes on: the item
    # says where it went (the new execution, queued) and no `result` wakes a
    # follower into reading a run that has not ended.
    def call
      items = [{ type: "run_status", payload: run_status }]
      preview = output_preview
      if preview.present?
        items << { type: "provider_output_item_completed",
                   payload: { "content_preview" => preview } }
      end
      if usage_payload.present?
        items << { type: "usage", payload: { "usage" => usage_payload } }
      end
      items << { type: "result", payload: { "result" => result_payload } } if @model_change.nil?
      items
    end

    private

      def run_status
        if @model_change
          { "status" => "queued", "model_change" => @model_change }
        else
          { "status" => @invocation.work_status }
        end
      end

      def result_payload
        {
          "status" => @invocation.work_status,
          "finish_quality" => @invocation.finish_quality,
          "refusal_category" => @invocation.refusal_category,
          "error" => error_payload,
          "inference_request_public_id" => @invocation.inference_request.public_id,
        }.compact
      end

      # The receipt is the sole normalized usage/cost fact. It belongs to the
      # Invocation's latest Attempt; an older receipt must never stand in for a
      # terminal retry whose own settlement is still pending.
      def receipt
        return @receipt if defined?(@receipt)

        @receipt = UsageRecord.for_latest_attempt(@invocation)
      end

      # The one public usage shape (UsageRecords::PublicUsage): the read
      # surface projects the same receipt through the same class, so replay
      # and reads always agree.
      def usage_payload
        return @usage_payload if defined?(@usage_payload)

        @usage_payload = UsageRecords::PublicUsage.render(receipt)
      end

      # This summary lets a follower classify a failed wake without carrying
      # the full terminal projection. The REST read remains authoritative.
      def error_payload
        ModelInvocations::PublicError.render(@invocation, receipt)
      end

      # The predecessor previewed the copied result body; this schema stores
      # the answer once, on the invocation, so the preview reads it there.
      def output_preview
        return nil unless @invocation.completed?

        bodies_by_role["response"]&.effective_text.to_s[0, PREVIEW_LENGTH].presence
      end

      def bodies_by_role
        @bodies_by_role ||= @invocation.content_bodies.to_a.index_by(&:role)
      end
  end
end
