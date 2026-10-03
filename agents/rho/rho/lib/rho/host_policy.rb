require_relative "store_document"

module Rho
  # Conversation policy in Nexus; one handle belongs to one admission or
  # restoration boundary. StoreDocument owns its cache and commit semantics.
  class HostPolicy
    NAMESPACE = "rho.host".freeze
    KEY = "policy".freeze
    KEEP = Object.new.freeze

    Snapshot = Data.define(:owner_public_id, :host_public_id, :model, :compose, :notes) do
      def self.from_h(value)
        document = value.to_h
        owner = document.fetch("owner_public_id").to_s
        host = document.fetch("host_public_id").to_s
        notes = Hash.try_convert(document.fetch("notes"))
        compose = document["compose"]
        if owner.empty? || host.empty? || notes.nil? || ![nil, true, false].include?(compose)
          raise Rho::StateError, "Invalid conversation policy in Nexus"
        end

        new(owner_public_id: owner, host_public_id: host, model: document["model"]&.to_s,
          compose: compose, notes: notes)
      end

      def to_h = super.transform_keys(&:to_s)
    end

    def initialize(store:, owner_public_id:, host_public_id:, initial: nil)
      @owner_public_id, @host_public_id = owner_public_id, host_public_id
      @document = StoreDocument.new(store: store, namespace: NAMESPACE, key: KEY,
        initial: (-> { legacy_policy(initial.call) } if initial))
    end

    def read
      value = @document.read
      inherited(Snapshot.from_h(value)) unless value.nil?
    end

    # A newly opened host explicitly replaces the policy a fork copied.
    def replace(model: nil, compose: nil, notes: {})
      value = @document.change do |document|
        document.replace(owned(model: model, compose: compose, notes: notes).to_h)
      end
      Snapshot.from_h(value)
    end

    # Unspecified fields survive; nil and false are values. An existing
    # conversation keeps its policy owner when another member changes it.
    def change(model: KEEP, compose: KEEP, notes: KEEP)
      value = @document.change do |document|
        current = document.empty? ? owned : inherited(Snapshot.from_h(document))
        document.replace(current.with(
          model: model.equal?(KEEP) ? current.model : model,
          compose: compose.equal?(KEEP) ? current.compose : compose,
          notes: notes.equal?(KEEP) ? current.notes : notes
        ).to_h)
      end
      Snapshot.from_h(value)
    end

    private

      def legacy_policy(value)
        if value
          { "notes" => {} }.merge(value, "owner_public_id" => @owner_public_id, "host_public_id" => @host_public_id)
        end
      end

      # Nexus copies store values on fork. Only the execution preferences
      # inherit; a parent's until goal or side bookkeeping must not restart
      # on the child. The first write records the child's own attribution.
      def inherited(snapshot)
        return snapshot if snapshot.host_public_id == @host_public_id

        owned(model: snapshot.model, compose: snapshot.compose)
      end

      def owned(model: nil, compose: nil, notes: {})
        Snapshot.new(owner_public_id: @owner_public_id, host_public_id: @host_public_id,
          model: model, compose: compose, notes: notes)
      end
  end
end
