module Rho
  # Explicit human authoring can initialize a missing Speaker default. Reads
  # never allocate, and an existing or deleted default is never replaced.
  module MemoryCollections
    def self.target(conversation:, path:, speaker_public_id: nil, client: nil)
      memory = conversation.memory(speaker_public_id: speaker_public_id)
      root = path.split("/", 2).first
      selected = memory.bindings.fetch("bindings").find { |binding| binding.fetch("name") == root }
      unless selected && selected.fetch("access") == "read_write"
        raise Rho::Error, "memory needs a writable binding in this conversation"
      end

      if selected.fetch("state") == "unallocated" && selected.fetch("source")["scope"] == "speaker" && client
        source = selected.slice("name", "source", "scope", "owner_public_id", "speaker_public_id")
        prepare_speaker_default(client, selected)
        selected = memory.bindings.fetch("bindings").find { |binding| binding.fetch("name") == root }
        unless selected && selected.slice(*source.keys) == source
          raise Rho::Error, "memory binding changed while initializing its collection"
        end
      end
      unless selected && selected.fetch("access") == "read_write" && selected.fetch("state") == "active" && selected["collection_public_id"]
        raise Rho::Error, "the selected memory collection is unavailable"
      end

      selected
    end

    def self.prepare_speaker_default(client, binding)
      owner_public_id = binding.fetch("owner_public_id")
      profile = client.profile
      collections = if profile.fetch.member.public_id == owner_public_id
        profile.memory_collections
      else
        agent = profile.agents.list.find { |row| row.public_id == owner_public_id }
        raise Rho::Error, "the answering Agent must initialize its Speaker memory" unless agent

        profile.agents.memory_collections(name: agent.name)
      end
      collections.create(default: true, speaker_public_id: binding.fetch("speaker_public_id"))
    end
    private_class_method :prepare_speaker_default
  end
end
