module WorkReports
  class RecentWork
    def self.call(user:, agent: nil, limit: 5)
      conversations = Conversation.visible_to(user).working.unarchived
      runs = Run.visible_to(user).where(variant_id: nil)
      if agent
        conversations = conversations.where(answering_user: agent)
        runs = runs.for_agent(agent.public_id)
      end
      conversations = conversations.includes(:workspace, :answering_user)
        .order(last_activity_at: :desc, id: :desc).limit(limit).to_a
      runs = runs.includes(:workspace).order(updated_at: :desc, id: :desc).limit(limit).to_a
      (conversations.map { |row| [row.last_activity_at, row] } + runs.map { |row| [row.updated_at, row] })
        .sort_by { |time, row| [time, row.public_id] }.last(limit).reverse.map(&:last)
    end
  end
end
