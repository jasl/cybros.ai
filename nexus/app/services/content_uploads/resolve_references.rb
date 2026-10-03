module ContentUploads
  # Creator-scoped, and the scope is only real if the refusal cannot be read as an
  # answer: another creator's, nonexistent and malformed all answer the same. No
  # database rescue: an outage is not a refusal.
  class ResolveReferences
    Result = Data.define(:uploads, :refusal) do
      def self.accepted(uploads) = new(uploads: uploads, refusal: nil)
      def self.refused(refusal) = new(uploads: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    REFUSAL = :unknown_input_upload
    # The executor commit's twin: a `resource_link` naming an upload that
    # is not the committer's own capture.
    RESULT_REFUSAL = :unknown_result_upload

    def self.call(...) = new(...).call

    # `lock:` pins the resolved rows `FOR KEY SHARE` for the caller's
    # transaction — the fragment writer's own primitive (`Replace#resolved_fragments`) — so the orphan reaper cannot `destroy!` a row
    # between this read and the join it is about to enter; without it the
    # bind's INSERT would meet a vanished row as an `InvalidForeignKey`, a
    # 500 where a 422 was promised. Only meaningful inside a transaction.
    # `creator` is the member the door acts for, or the executor whose
    # commit names its own captures: one class, one lock, the creator's
    # anchor as the scope.
    def initialize(account:, creator:, public_ids:, lock: false)
      @account = account
      @creator = creator
      @public_ids = public_ids
      @lock = lock
    end

    def call
      references = @public_ids
      return Result.accepted([]) if references.empty?

      found = resolvable.where(public_id: references.compact).index_by(&:public_id)
      # One lookup, then order restored from the submission — a repeated
      # reference resolves to the same row at each requested position.
      uploads = references.map { |reference| found[reference] }
      return Result.refused(REFUSAL) if uploads.any?(&:nil?)

      Result.accepted(uploads)
    end

    private

      def resolvable
        relation = @account.content_uploads
          .where(@creator.content_upload_anchor)
          .joins(file_attachment: :blob)
          .with_attached_file
        @lock ? relation.lock("FOR KEY SHARE OF content_uploads") : relation
      end
  end
end
