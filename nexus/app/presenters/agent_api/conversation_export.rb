module AgentAPI
  # An each-only Rack body: one observation interval, no export job or retained
  # snapshot. Every page is projected before returning its connection to the pool.
  class ConversationExport < ExecutionExport
    FORMAT = "nexus.conversation.diagnostic".freeze
    VERSION = 1
    SCOPE = "retained_conversation".freeze
    include Timeline

    def initialize(conversation:, user:)
      @conversation = conversation
      @user = user
    end

    private

      def records
        yield({ type: "export", format: FORMAT, version: VERSION,
          conversation_public_id: @conversation.public_id, exported_at: Time.current.iso8601,
          scope: SCOPE, consistency: CONSISTENCY })
        projection = read { AgentAPI::ConversationPresenter.full(@conversation, acting_user: @user) }
        yield envelope("conversation", conversation: projection)
        inputs { |record| yield record }
        timeline { |record| yield record }
        usage { |record| yield record }
        events { |record| yield record }
      end

      def envelope(type, **fields)
        { type: type, conversation_public_id: @conversation.public_id, **fields }
      end

      def inputs
        ceiling = read { @conversation.inputs.maximum(:id) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            rows = @conversation.inputs.where(id: (cursor + 1)..ceiling).order(:id).limit(PAGE_SIZE)
              .preload(:answering_user, { speaker: :user }, :content_bodies).to_a
            ContentBody.preload_for_render(rows.flat_map(&:content_bodies))
            rows.map do |input|
              input.association(:host).target = @conversation
              [input.id, AgentAPI::ConversationPresenter.input(input)]
            end
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("input", input: projection) }
        end
      end

      def usage
        scope = UsageRecord.where(account_id: @conversation.account_id,
          conversation_public_id: @conversation.public_id)
        ceiling = read { scope.maximum(:id) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            scope.where(id: (cursor + 1)..ceiling).order(:id).limit(PAGE_SIZE).map do |receipt|
              projection = UsageRecords::PublicUsage.diagnostic(receipt)
              [receipt.id, projection]
            end
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("usage", usage: projection) }
        end
      end

      def events
        ceiling = read { @conversation.event_items.maximum(:sequence) }
        cursor = 0
        while ceiling && cursor < ceiling
          page = read do
            @conversation.event_items.where(sequence: (cursor + 1)..ceiling)
              .order(:sequence).limit(PAGE_SIZE).map do |item|
                item.association(:host).target = @conversation
                [item.sequence, EventItem::PublicProjection.render(item)]
              end
          end
          break if page.empty?

          cursor = page.last.first
          page.each { |_, projection| yield envelope("event", event: projection) }
        end
      end
  end
end
