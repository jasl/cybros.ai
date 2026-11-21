# The queue's wake after admission, settlement, editing or periodic recovery.
# Level-triggered: the drain re-reads the head under the lock, so a
# duplicate kick is never a double apply.
class Conversations::Inputs::DrainJob < ApplicationJob
  def perform(conversation_id)
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation_id)
  end
end
