# Fixture authors explicitly observe a row before constructing their mutation.
# Tests for stale requests retain that value and never refresh it on retry.
module MemoryTestHelper
  # Fixture setup names its owner directly. Product selection and authorization
  # are exercised through MemoryDocuments::Context, never this constructor.
  def memory_anchor(path:, workspace: nil, conversation: nil, user: nil, agent: nil, speaker: nil)
    scope, name = Scopes::Anchor.split(path)
    return Scopes::Anchor.refused(:memory_path_invalid) if name.nil? || !MemoryContext::SCOPES.include?(scope.to_sym)

    owner = { "conversation" => conversation, "workspace" => workspace, "user" => user,
      "agent" => agent, "speaker" => (agent if speaker) }.fetch(scope)
    collection = owner&.memory_collections&.find_by(is_default: true, speaker: (speaker if scope == "speaker"))
    return Scopes::Anchor.refused(:memory_scope_unavailable) if collection.nil? || collection.deleted?

    Scopes::Anchor::Result.new(collection: collection, scope: scope, name: name, refusal: nil)
  end

  def memory_expectation(document = nil)
    MemoryDocuments::Precondition.new(public_id: document&.public_id, lock_version: document&.lock_version)
  end

  def memory_expectation_at(anchor)
    memory_expectation(anchor.documents.find_by(name: anchor.name))
  end

  def memory_expectation_for(conversation:, path:, by:)
    context = MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation,
      principal: by, configuration: conversation.effective_memory_context, agent: conversation.answering_agent)
    anchor = context.resolve(path)
    anchor.resolved? ? memory_expectation_at(anchor) : memory_expectation
  end

  def memory_collection_condition(conversation:, path:, by:, speaker: nil)
    context = MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation,
      principal: by, configuration: conversation.reload.effective_memory_context(speaker: speaker), agent: conversation.answering_agent)
    anchor = context.resolve(path)
    { expected_collection_public_id: anchor.resolved? ? anchor.collection.public_id : SecureRandom.uuid_v7 }
  end

  def memory_conditions(document = nil)
    { expected_collection_public_id: document&.memory_collection&.public_id,
      expected_public_id: document&.public_id, expected_lock_version: document&.lock_version }
  end

  # Committed fixtures explicitly tear down their own aggregate. Empty birth
  # defaults are real rows too; keep the production owner FK and drain first.
  def destroy_memory_owner!(owner)
    return unless owner

    owner.with_lock do
      while owner.memory_collections.exists?
        MemoryCollections::Drain.call(owner: owner, budget: 64)
      end
      owner.destroy!
    end
  end
end
