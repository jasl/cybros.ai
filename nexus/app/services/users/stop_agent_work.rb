module Users
  # Immediate wakes name one Agent; the recurring floor walks live work once
  # for all removed Agents. Restore makes either form harmless.
  class StopAgentWork
    BATCH = 200
    LIVE_LOOPS_SQL = "(runs.status)::text = ANY (ARRAY['pending'::text, 'running'::text, " \
      "'canceling'::text, 'paused'::text, 'needs_attention'::text])".freeze

    def self.call(...) = new(...).call

    def initialize(user_id: nil, conversation_after_id: 0, loop_after_id: 0, batch: BATCH)
      @user_id = user_id
      @conversation_after_id = conversation_after_id
      @loop_after_id = loop_after_id
      @batch = batch
    end

    def call
      return finished if @user_id && !removed_agents.exists?

      turns = turn_window
      loops = loop_window
      stopped_turns = related_conversations(turns).count { |id| stop_conversation(id) }
      stopped_loops = related_loops(loops).count { |id| stop_loop(id) }
      cursors = [cursor(turns, @conversation_after_id), cursor(loops, @loop_after_id)]
      Conversations::Turns::ConvergeJob.perform_later if stopped_turns.positive? || stopped_loops.positive?

      Sweeps::Pass.new(
        counts: { scanned: turns.length + loops.length, conversations_stopped: stopped_turns, loops_stopped: stopped_loops },
        cursor: { conversation_after_id: cursors.first, loop_after_id: cursors.last }, more: cursors.any?
      )
    end

    private

      def finished
        Sweeps::Pass.new(counts: { scanned: 0, conversations_stopped: 0, loops_stopped: 0 },
          cursor: { conversation_after_id: nil, loop_after_id: nil }, more: false)
      end

      def removed_agents
        agents = User.where(kind: :agent, status: :removed)
        return agents unless @user_id

        agents.where(id: @user_id)
          .or(agents.where(derived_from_id: @user_id, named_agent_scope: :instance))
      end

      def turn_window
        return [] if @conversation_after_id.nil?

        Turn.active.where(conversation_id: (@conversation_after_id + 1)..)
          .order(:conversation_id).limit(@batch).pluck(:conversation_id)
      end

      def loop_window
        return [] if @loop_after_id.nil?

        Run.where(LIVE_LOOPS_SQL).where(id: (@loop_after_id + 1)..)
          .order(:id).limit(@batch).pluck(:id)
      end

      def cursor(ids, previous)
        ids.last if previous && @batch.positive? && ids.length == @batch
      end

      def related_conversations(ids)
        return [] if ids.empty?

        # Walk only the ancestry of this materialized work window. The spawn
        # edge preserves who commissioned a child after its parent turn settles;
        # arbitrary historical turns and fork prefixes never enter this relation.
        sql = Conversation.sanitize_sql_array([<<~SQL, ids])
          WITH RECURSIVE ancestry AS (
            SELECT id AS origin_id, id, parent_conversation_id, creating_user_id,
              answering_user_id, spawn_node_id, taken_over_at
            FROM conversations WHERE id IN (?)
            UNION ALL
            SELECT ancestry.origin_id, parent.id, parent.parent_conversation_id,
              parent.creating_user_id, parent.answering_user_id, parent.spawn_node_id, parent.taken_over_at
            FROM conversations AS parent
            INNER JOIN ancestry ON parent.id = ancestry.parent_conversation_id
              AND ancestry.taken_over_at IS NULL
          )
          SELECT DISTINCT ancestry.origin_id
          FROM ancestry
          LEFT JOIN turns AS current_turn
            ON current_turn.conversation_id = ancestry.id
              AND current_turn.status IN ('pending', 'running')
          LEFT JOIN tasks AS spawn_node ON spawn_node.id = ancestry.spawn_node_id AND ancestry.taken_over_at IS NULL
          LEFT JOIN runs AS spawn_loop ON spawn_loop.id = spawn_node.run_id
          INNER JOIN users ON users.id IN (
            ancestry.creating_user_id, ancestry.answering_user_id,
            current_turn.control_owner_user_id, current_turn.answering_user_id,
            spawn_loop.creating_user_id
          )
          WHERE users.id IN (#{removed_agents.select(:id).to_sql})
        SQL
        Conversation.lease_connection.select_values(sql)
      end

      def related_loops(ids)
        return [] if ids.empty?

        rows = Run.where(id: ids).where(LIVE_LOOPS_SQL)
          .left_joins(variant: :turn)
          .pluck(:id, :creating_user_id, "turns.answering_user_id", "turns.conversation_id")
        agents = removed_agents.where(id: rows.flat_map { |_, creator, answerer, _| [creator, answerer] }.compact)
          .pluck(:id)
        conversations = related_conversations(rows.map(&:last).compact.uniq)
        rows.filter_map do |id, creator, answerer, conversation_id|
          id if agents.include?(creator) || agents.include?(answerer) || conversations.include?(conversation_id)
        end
      end

      def stop_conversation(id)
        conversation = Conversation.find_by(id: id)
        return false if conversation.nil?

        conversation.with_lock do
          # Recheck current roles after the Conversation arbiter: discovery must
          # never cancel a newer unrelated turn, or work begun after restore.
          related = ApplicationRecord.uncached { related_conversations([id]).any? }
          related && Conversations::Turns::Cancel.stop_now(conversation).accepted?
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: {
          event: "agent_removal_conversation_stop_failed", conversation_public_id: conversation&.public_id,
        })
        false
      end

      def stop_loop(id)
        run = Run.find_by(id: id)
        return false if run.nil?

        run.with_lock do
          # This loop is the target even when a newer turn now owns its room.
          related = ApplicationRecord.uncached { related_loops([id]).any? }
          related && Runs::Stop.stop_now(run).accepted?
        end
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: {
          event: "agent_removal_loop_stop_failed", run_public_id: run&.public_id,
        })
        false
      end
  end
end
