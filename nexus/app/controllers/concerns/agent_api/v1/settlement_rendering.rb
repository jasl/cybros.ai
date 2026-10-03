# ONE renderer for every door over `Parks::Settle`: the executor commit and
# the person's resolution answer the same way — the settled task, or the
# engine's own typed refusal. Payload-shaped refusals are 422
# (`result_unstorable` means these bytes can never be stored, which a 409
# "try again" would contradict); absence is 404; every other refusal — a
# dead token, a row not addressed here, a lost standing — is a reachable
# conflict at 409.
module AgentAPI::V1::SettlementRendering
  extend ActiveSupport::Concern

  PAYLOAD_REFUSALS = %i[
    metadata_too_large invalid_metadata invalid_title invalid_content
    unsupported_content_kind invalid_result_type too_many_content_blocks
    result_unstorable unknown_result_upload
  ].freeze

  private

    def render_settlement(result, node)
      case result.outcome
      when :applied, :idle
        render json: { task: AgentAPI::AgentLoopPresenter.task(node.reload) }
      when :result_too_large
        render_error(:result_too_large, "Result exceeds the 1 MB payload boundary",
          status: :unprocessable_entity)
      when *PAYLOAD_REFUSALS
        render_error(result.outcome.to_s, "Refused: #{result.outcome}",
          status: :unprocessable_entity)
      when :not_found
        render_error(:not_found, "Not found", status: :not_found)
      else
        render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
      end
    end
end
