require_relative "store_document"

module Rho
  # Home and audience belong to the declaring profile's Store. The runtime
  # declaration is derived from this audience at the ordinary declaration edge.
  class BotSettings
    NAMESPACE = "rho.bots".freeze
    CONVERSATION_METADATA_KEY = "rho_bot_public_id".freeze
    AUDIENCES = %w[owner external].freeze
    KEEP = Object.new.freeze

    Snapshot = Data.define(:home_workspace_public_id, :audience, :preset_public_id, :welcome_message, :subagent) do
      def initialize(preset_public_id: nil, welcome_message: nil, subagent: true, **fields) = super(preset_public_id: preset_public_id, welcome_message: welcome_message, subagent: subagent, **fields)

      def to_h = super.transform_keys(&:to_s)
    end

    def initialize(store:, agent_public_id:)
      @document = StoreDocument.new(store: store, namespace: NAMESPACE, key: agent_public_id)
    end

    def read
      snapshot(@document.read.to_h)
    end

    def replace(home_workspace_public_id: KEEP, audience: KEEP, preset_public_id: KEEP, welcome_message: KEEP, subagent: KEEP)
      saved = nil
      @document.change do |document|
        current = snapshot(document)
        saved = Snapshot.new(
          home_workspace_public_id: KEEP.equal?(home_workspace_public_id) ? current.home_workspace_public_id : home_workspace_public_id,
          audience: KEEP.equal?(audience) ? current.audience : audience,
          preset_public_id: KEEP.equal?(preset_public_id) ? current.preset_public_id : preset_public_id,
          welcome_message: KEEP.equal?(welcome_message) ? current.welcome_message : welcome_message,
          subagent: KEEP.equal?(subagent) ? current.subagent : subagent
        )
        document.replace(saved.to_h)
      end
      saved
    end

    private

      def snapshot(document)
        Snapshot.new(home_workspace_public_id: document["home_workspace_public_id"], audience: document.fetch("audience", "owner"),
          preset_public_id: document["preset_public_id"], welcome_message: document["welcome_message"], subagent: document.fetch("subagent", true))
      end
  end
end
