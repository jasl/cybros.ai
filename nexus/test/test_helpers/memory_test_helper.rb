# Fixture authors explicitly observe a row before constructing their mutation.
# Tests for stale requests retain that value and never refresh it on retry.
module MemoryTestHelper
  def memory_expectation(document = nil)
    MemoryDocuments::Precondition.new(public_id: document&.public_id, lock_version: document&.lock_version)
  end

  def memory_expectation_at(anchor)
    memory_expectation(anchor.documents.find_by(name: anchor.name))
  end

  def memory_expectation_for(conversation:, path:, by:)
    anchor = Scopes::Anchor.call(path: path, workspace: conversation.workspace,
      conversation: conversation, user: by.controlling_human)
    anchor.resolved? ? memory_expectation_at(anchor) : memory_expectation
  end

  def memory_conditions(document = nil)
    { expected_public_id: document&.public_id, expected_lock_version: document&.lock_version }
  end
end
