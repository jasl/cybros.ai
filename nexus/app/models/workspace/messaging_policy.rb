# A Workspace owns the whole bounded policy. Each entry belongs to the receiving
# Agent; Public retains its sender list so a later switch to Private can reuse it.
class Workspace::MessagingPolicy
  include StoreModel::Model

  class AgentPolicy
    include StoreModel::Model

    MODES = %w[public private].freeze

    attribute :agent_public_id, :string
    attribute :mode, :string
    attribute :allowed_sender_public_ids, default: -> { [] }

    normalizes :agent_public_id, with: ->(value) { value.downcase }
    normalizes :allowed_sender_public_ids, with: ->(values) { values.map { |value| value.to_s.downcase }.uniq }

    validates :agent_public_id, length: { is: 36 }, format: { with: User::Handle::PUBLIC_ID_FORMAT }
    validates :mode, inclusion: { in: MODES }
    validate :senders_are_public_ids

    private

      def senders_are_public_ids
        unless allowed_sender_public_ids.all? { |public_id| public_id.length == 36 && public_id.match?(User::Handle::PUBLIC_ID_FORMAT) }
          errors.add(:allowed_sender_public_ids, :invalid)
        end
      end
  end

  attribute :agents, AgentPolicy.to_array_type, default: -> { [] }

  validates :agents, store_model: true
  validate :agents_are_unique

  private

    def agents_are_unique
      if agents && agents.map(&:agent_public_id).uniq.length != agents.length
        errors.add(:agents, :invalid)
      end
    end
end
