require_relative "store_document"

module Rho
  # Conversation policy in Nexus; one handle belongs to one admission or
  # restoration boundary. StoreDocument owns its cache and commit semantics.
  class HostPolicy
    NAMESPACE = "rho.host".freeze
    KEY = "policy".freeze
    KEEP = Object.new.freeze

    Snapshot = Data.define(:owner_public_id, :host_public_id, :model, :notes, :code_mode) do
      def initialize(code_mode: nil, **fields) = super(code_mode: code_mode, **fields)

      def self.from_h(value)
        document = value.to_h
        owner = document.fetch("owner_public_id").to_s
        host = document.fetch("host_public_id").to_s
        notes = Hash.try_convert(document.fetch("notes"))
        if owner.empty? || host.empty? || notes.nil? || ![nil, true, false].include?(document["code_mode"])
          raise Rho::StateError, "Invalid conversation policy in Nexus"
        end

        new(owner_public_id: owner, host_public_id: host, model: document["model"]&.to_s,
          notes: notes, code_mode: document["code_mode"])
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

    # A newly opened host explicitly replaces the policy a fork copied.
    def replace(model: nil, notes: {}, code_mode: nil)
      value = @document.change do |document|
        document.replace(owned(model: model, notes: notes, code_mode: code_mode).to_h)
      end
      Snapshot.from_h(value)
    end

    # Unspecified fields survive; nil clears the model or code-mode override. An existing
    # conversation keeps its policy owner when another member changes it.
    def change(model: KEEP, notes: KEEP, code_mode: KEEP)
      value = @document.change do |document|
        current = document.empty? ? owned : inherited(Snapshot.from_h(document))
        document.replace(current.with(
          model: model.equal?(KEEP) ? current.model : model,
          notes: notes.equal?(KEEP) ? current.notes : notes,
          code_mode: code_mode.equal?(KEEP) ? current.code_mode : code_mode
        ).to_h)
      end
      Snapshot.from_h(value)
    end

    private

      # Nexus copies store values on fork. Only the execution preferences
      # inherit; a parent's until goal or side bookkeeping must not restart
      # on the child. The first write records the child's own attribution.
      def inherited(snapshot)
        return snapshot if snapshot.host_public_id == @host_public_id

        owned(model: snapshot.model, code_mode: snapshot.code_mode)
      end

      def owned(model: nil, notes: {}, code_mode: nil)
        Snapshot.new(owner_public_id: @owner_public_id, host_public_id: @host_public_id,
          model: model, notes: notes, code_mode: code_mode)
      end
  end
end
