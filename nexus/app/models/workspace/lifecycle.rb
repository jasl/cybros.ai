module Workspace::Lifecycle
  extend ActiveSupport::Concern

  # Acceptance commits the authority state immediately; the timestamps
  # are evidence, never a second state machine.

  # Archive and delete first-stop in the same transaction as the state write;
  # restore never resurrects an accepted cancellation.

  def accept_archive
    update!(state: :archiving, archived_at: Time.current)
    stop_model_work("workspace_archived")
  end

  def accept_restore
    update!(state: :restoring, archived_at: nil)
  end

  def accept_delete
    update!(state: :deleting, deleted_at: Time.current)
    stop_model_work("workspace_deleted")
  end

  # Advance exactly one transition; the authoritative integrity seam later
  # descendant kinds extend through `descendants_pending?`. Restoring is
  # ungated — it destroys nothing.
  def complete_transition
    case state
    when "archiving"
      return :descendants_pending if descendants_pending?

      update!(state: :archived)
      :completed
    when "restoring"
      update!(state: :active)
      :completed
    when "deleting"
      return :descendants_pending if descendants_pending?

      update!(state: :deleted)
      :completed
    else
      :nothing_to_complete
    end
  end

  # Invocation truth, and after the course correction that is the only truth
  # there is: no second row can hold a Workspace open after its work finished,
  # or let one through while work is still live.
  def descendants_pending?
    ModelInvocation.where(workspace_id: id).nonterminal.exists?
  end

  private

    def stop_model_work(reason)
      ModelInvocation::Cancellation.call(
        scope: ModelInvocation.where(workspace_id: id), reason: reason
      )
    end
end
