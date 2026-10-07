module InferenceRequests
  # The shared, write-free preparation for a submitted InferenceRequest input.
  # Selection, upload resolution, and workload normalization must answer the
  # same way whether the caller is creating work or asking for an estimate.
  class PrepareInput
    Result = Data.define(:selection, :normalized, :refusal) do
      def self.accepted(selection:, normalized:)
        new(selection: selection, normalized: normalized, refusal: nil)
      end

      def self.refused(refusal) = new(selection: nil, normalized: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    def self.call(...) = new(...).call

    # `lock:` is the door's word (`ContentUploads::ResolveReferences`): the
    # create path resolves inside its lock section and pins the rows `FOR
    # KEY SHARE` against the orphan reaper; the estimate has no transaction
    # and no join to protect, so it reads plain.
    def initialize(account:, creating_user:, workload:, submitted:, configuration:,
                   input:, upload_public_ids:, port: ModelSelection::UNAVAILABLE_PORT,
                   lock: false)
      @account = account
      @creating_user = creating_user
      @workload = workload
      @submitted = submitted
      @configuration = configuration
      @input = input
      @upload_public_ids = upload_public_ids
      @port = port
      @lock = lock
    end

    def call
      selection = ModelSelection.resolve(
        account: @account, workload: @workload, submitted: @submitted,
        configuration: @configuration, port: @port
      )
      return Result.refused(selection.refusal) unless selection.resolved?

      uploads = ContentUploads::ResolveReferences.call(
        account: @account, creator: @creating_user, public_ids: @upload_public_ids,
        lock: @lock
      )
      return Result.refused(uploads.refusal) unless uploads.accepted?

      normalized = ModelSelection::Workloads.normalize_workload_input(
        selection: selection.selection, input: @input, uploads: uploads.uploads
      )
      return Result.refused(normalized.refusal) unless normalized.accepted?

      Result.accepted(selection: selection.selection, normalized: normalized.value)
    end
  end
end
