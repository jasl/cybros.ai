module OneShots
  # Advisory input sizing for clients deciding whether to compact or trim.
  # It runs the same write-free preparation as create, then counts locally;
  # it never persists the estimate and never contacts a Provider.
  class InputEstimate
    Command = Data.define(
      :workspace, :creating_user, :workload, :submitted, :configuration,
      :input, :upload_public_ids
    )

    Estimate = Data.define(
      :input_tokens, :tokenizer_exact, :catalog_input_token_limit,
      :advisory_input_token_limit, :selection
    )

    Result = Data.define(:estimate, :refusal) do
      def self.estimated(estimate) = new(estimate: estimate, refusal: nil)
      def self.refused(refusal) = new(estimate: nil, refusal: refusal)

      def estimated? = refusal.nil?
    end

    def self.call(...) = new(...).call

    def initialize(command:, port: ModelSelection::UNAVAILABLE_PORT)
      @command = command
      @port = port
    end

    def call
      input = CoerceTextMessages.call(@command.input)
      configuration = CoerceConfiguration.call(@command.configuration)
      upload_public_ids = Array(@command.upload_public_ids).map do |public_id|
        ContentUpload.canonical_public_id(public_id)
      end

      prepared = PrepareInput.call(
        account: @command.workspace.account,
        creating_user: @command.creating_user,
        workload: @command.workload,
        submitted: @command.submitted,
        configuration: configuration,
        input: input,
        upload_public_ids: upload_public_ids,
        port: @port
      )
      return Result.refused(prepared.refusal) unless prepared.accepted?

      selection = prepared.selection
      counted = ModelRequests::TokenCount.count(
        profile: selection.execution_profile,
        segments: Nexus::ModelRequestInput.text_segments(prepared.normalized.value)
      )
      return Result.refused(counted.refusal) unless counted.counted?

      limits = selection.capabilities.limits
      Result.estimated(Estimate.new(
        input_tokens: counted.tokens,
        tokenizer_exact: counted.exact?,
        catalog_input_token_limit: limits.input_token_bound,
        advisory_input_token_limit: limits.advisory_input_bound,
        selection: selection
      ))
    end
  end
end
