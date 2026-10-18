module InferenceRequests
  # The shared, write-free preparation for a submitted InferenceRequest input.
  # Selection, upload resolution, and workload normalization must answer the
  # same way whether the caller is creating work or asking for an estimate.
  class PrepareInput
    Result = Data.define(:selection, :normalized, :model_selection, :fallback_models, :skips, :refusal) do
      def self.accepted(selection:, normalized:, model_selection:, fallback_models:, skips:)
        new(selection: selection, normalized: normalized, model_selection: model_selection,
          fallback_models: fallback_models, skips: skips, refusal: nil)
      end

      def self.refused(refusal) = new(selection: nil, normalized: nil, model_selection: nil, fallback_models: nil, skips: [], refusal: refusal)

      def accepted? = refusal.nil?
    end

    def self.call(...) = new(...).call

    # `lock:` is the door's word (`ContentUploads::ResolveReferences`): the
    # create path resolves inside its lock section and pins the rows `FOR
    # KEY SHARE` against the orphan reaper; the estimate has no transaction
    # and no join to protect, so it reads plain.
    def initialize(account:, creating_user:, workload:, submitted:, configuration:,
                   input:, upload_public_ids:, port: ModelSelection::UNAVAILABLE_PORT,
                   lock: false, model_selection: nil, fallback_models: nil)
      @account = account
      @creating_user = creating_user
      @workload = workload
      @submitted = submitted
      @model_selection = ModelSelectionIntent.to_type.cast(model_selection) || ModelSelectionIntent.default(submitted.model)
      @fallback_models = fallback_models || creating_user.fallback_models || []
      @configuration = configuration
      @input = input
      @upload_public_ids = upload_public_ids
      @port = port
      @lock = lock
    end

    def call
      return Result.refused(:model_selection_invalid) unless @model_selection.valid?
      return Result.refused(:fallback_models_invalid) unless ModelReferencesValidator.valid_value?(@fallback_models)

      selection = ModelSelection::Recovery.resolve(
        account: @account, workload: @workload, submitted: @submitted,
        configuration: @configuration, model_selection: @model_selection,
        fallback_models: @fallback_models, port: @port
      ) do |candidate|
        uploads = resolve_uploads
        if uploads.accepted?
          normalized = ModelSelection::Workloads.normalize_workload_input(
            selection: candidate, input: @input, uploads: uploads.uploads)
          normalized.accepted? ? ModelSelection::Recovery.context_refusal(candidate, normalized.value.value) : normalized.refusal
        else
          uploads.refusal
        end
      end
      return Result.refused(selection.refusal) unless selection.resolved?

      uploads = resolve_uploads
      return Result.refused(uploads.refusal) unless uploads.accepted?

      normalized = ModelSelection::Workloads.normalize_workload_input(
        selection: selection.selection, input: @input, uploads: uploads.uploads
      )
      return Result.refused(normalized.refusal) unless normalized.accepted?

      Result.accepted(selection: selection.selection, normalized: normalized.value,
        model_selection: @model_selection, fallback_models: @fallback_models, skips: selection.skips)
    end

    private

      def resolve_uploads
        @resolved_uploads ||= ContentUploads::ResolveReferences.call(
          account: @account, creator: @creating_user, public_ids: @upload_public_ids, lock: @lock)
      end
  end
end
