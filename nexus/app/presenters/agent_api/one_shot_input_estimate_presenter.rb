module AgentAPI
  class OneShotInputEstimatePresenter
    class << self
      def full(estimate)
        selection = estimate.selection
        {
          input_tokens: estimate.input_tokens,
          tokenizer_exact: estimate.tokenizer_exact,
          catalog_input_token_limit: estimate.catalog_input_token_limit,
          advisory_input_token_limit: estimate.advisory_input_token_limit,
          model: {
            provider_id: selection.provider_id,
            model_ref: selection.model_ref,
            reasoning_effort: selection.reasoning.effort,
          },
        }.compact
      end
    end
  end
end
