module Runs
  # A source window, not a matching-results list. Filtering happens only after
  # materialization so empty pages advance without scanning unrelated history.
  class Candidates
    class InvalidCursor < StandardError; end

    SOURCE_STATUSES = %w[pending running canceling paused needs_attention].freeze
    STATUSES = %w[running paused needs_attention].freeze
    LIMIT = 50
    Candidate = Data.define(:public_id, :workspace_public_id, :conversation_public_id, :turn_public_id, :status)
    Page = Data.define(:runs, :next_after)

    def initialize(user:, agent_public_id:, after: nil)
      @user, @agent_public_id, @after = user, agent_public_id, after
    end

    def call
      position, ceiling = cursor
      rows = source.where(id: (position + 1)..ceiling).order(:id).limit(LIMIT).to_a
      next_after = if rows.length == LIMIT && rows.last.id < ceiling
        encryptor.encrypt_and_sign([rows.last.id, ceiling], purpose: purpose)
      end
      Page.new(runs: project(rows), next_after: next_after)
    end

    private

      def source = Run.where(status: SOURCE_STATUSES)

      def purpose = "run_candidates:#{@user.public_id}:#{@agent_public_id}"

      def encryptor
        key = Rails.application.key_generator.generate_key("run_candidates", 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON, url_safe: true)
      end

      def cursor
        return [0, source.order(id: :desc).pick(:id) || 0] if @after.blank?

        encryptor.decrypt_and_verify(@after, purpose: purpose) || raise(InvalidCursor)
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise InvalidCursor
      end

      def project(rows)
        rows = rows.select { |row| row.tombstoned_at.nil? && STATUSES.include?(row.status) && row.variant_id }
        return [] if rows.empty?

        agent = User.find_by(account_id: @user.account_id, kind: :agent, public_id: @agent_public_id)
        return [] unless agent

        variants = Variant.where(id: rows.map(&:variant_id)).index_by(&:id)
        turns = Turn.where(id: variants.values.map(&:turn_id)).index_by(&:id)
        rows = rows.select { |row| turns[variants[row.variant_id]&.turn_id]&.answering_user_id == agent.id }
        conversations = Conversation.where(id: rows.map { |row| turns.fetch(variants.fetch(row.variant_id).turn_id).conversation_id }).to_a
        workspaces = Workspace.where(id: conversations.map(&:workspace_id)).index_by(&:id)
        conversations.select! do |row|
          workspace = workspaces.fetch(row.workspace_id)
          workspace.browsable? && workspace.data_accessible_by?(@user)
        end
        readable = Conversation.readable_ids(conversations, user: @user)
        conversations = conversations.index_by(&:id)
        rows.filter_map do |row|
          turn = turns.fetch(variants.fetch(row.variant_id).turn_id)
          next unless readable.include?(turn.conversation_id)

          conversation = conversations.fetch(turn.conversation_id)
          Candidate.new(public_id: row.public_id, workspace_public_id: workspaces.fetch(conversation.workspace_id).public_id,
            conversation_public_id: conversation.public_id, turn_public_id: turn.public_id, status: row.status)
        end
      end
  end
end
