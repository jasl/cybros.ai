require_relative "store_document"

module Rho
  # Conversation policy in Nexus; one handle belongs to one admission or
  # restoration boundary. StoreDocument owns its cache and commit semantics.
  class HostPolicy
    NAMESPACE = "rho.host".freeze
    KEY = "policy".freeze
    KEEP = Object.new.freeze

    Snapshot = Data.define(:owner_public_id, :host_public_id, :model, :notes, :code_mode, :subagent, :model_selection, :title_pending, :title_input_public_id) do
      def initialize(code_mode: true, subagent: true, model_selection: nil, title_pending: false, title_input_public_id: nil, **fields)
        super(code_mode: code_mode, subagent: subagent, model_selection: model_selection, title_pending: title_pending, title_input_public_id: title_input_public_id, **fields)
      end

      def self.from_h(value)
        document = value.to_h
        owner = document.fetch("owner_public_id").to_s
        host = document.fetch("host_public_id").to_s
        notes = Hash.try_convert(document.fetch("notes"))
        if owner.empty? || host.empty? || notes.nil? || ![nil, true, false].include?(document["code_mode"]) || ![nil, true, false].include?(document["subagent"]) || ![nil, true, false].include?(document["title_pending"])
          raise Rho::StateError, "Invalid conversation policy in Nexus"
        end

        # Historical unset choices use the original product defaults. Reading
        # an existing conversation never consults mutable installation settings.
        new(owner_public_id: owner, host_public_id: host, model: document["model"]&.to_s,
          notes: notes, code_mode: document["code_mode"] != false, subagent: document["subagent"] != false, model_selection: document["model_selection"]&.to_h,
          title_pending: document["title_pending"] == true, title_input_public_id: document["title_input_public_id"]&.to_s)
      end

      def to_h = super.transform_keys(&:to_s)
    end

    def initialize(store:, owner_public_id:, host_public_id:)
      @owner_public_id, @host_public_id = owner_public_id, host_public_id
      @document = StoreDocument.new(store: store, namespace: NAMESPACE, key: KEY)
    end

    def read
      value = @document.read
      inherited(Snapshot.from_h(value)) unless value.nil?
    end

    # Initialize once. A creation replay preserves the entire committed value;
    # only a fork's copied parent policy is replaced with the child's own policy.
    def establish(model: nil, notes: {}, code_mode: true, subagent: true, model_selection: nil, title_pending: false)
      value = @document.change do |document|
        current = Snapshot.from_h(document) unless document.empty?
        next if current && current.host_public_id == @host_public_id

        document.replace(owned(model: model, notes: notes, code_mode: code_mode, subagent: subagent, model_selection: model_selection,
          title_pending: title_pending).to_h)
      end
      Snapshot.from_h(value)
    end

    # Unspecified fields survive; nil clears the model. An existing
    # conversation keeps its policy owner when another member changes it.
    def change(model: KEEP, notes: KEEP, code_mode: KEEP, subagent: KEEP, model_selection: KEEP)
      value = @document.change do |document|
        current = document.empty? ? owned : inherited(Snapshot.from_h(document))
        document.replace(current.with(
          model: model.equal?(KEEP) ? current.model : model,
          notes: notes.equal?(KEEP) ? current.notes : notes,
          code_mode: code_mode.equal?(KEEP) ? current.code_mode : code_mode,
          subagent: subagent.equal?(KEEP) ? current.subagent : subagent,
          model_selection: model_selection.equal?(KEEP) ? current.model_selection : model_selection
        ).to_h)
      end
      Snapshot.from_h(value)
    end

    def consume_title(input_public_id)
      consumed = false
      @document.change do |document|
        current = document.empty? ? owned : inherited(Snapshot.from_h(document))
        if current.title_pending
          document.replace(current.with(title_pending: false, title_input_public_id: input_public_id).to_h)
          consumed = true
        end
      end
      consumed
    end

    private

      # Nexus copies store values on fork. Only the execution preferences
      # inherit; a parent's until goal or side bookkeeping must not restart
      # on the child. The first write records the child's own attribution.
      def inherited(snapshot)
        return snapshot if snapshot.host_public_id == @host_public_id

        owned(model: snapshot.model, code_mode: snapshot.code_mode, subagent: snapshot.subagent, model_selection: snapshot.model_selection)
      end

      def owned(model: nil, notes: {}, code_mode: true, subagent: true, model_selection: nil, title_pending: false, title_input_public_id: nil)
        Snapshot.new(owner_public_id: @owner_public_id, host_public_id: @host_public_id,
          model: model, notes: notes, code_mode: code_mode, subagent: subagent, model_selection: model_selection,
          title_pending: title_pending, title_input_public_id: title_input_public_id)
      end
  end
end
