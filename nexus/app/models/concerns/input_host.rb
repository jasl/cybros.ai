# The waiting-room trait: a row that hosts `conversation_inputs`
# answers the door's questions itself, so the one door body — accept, edit,
# give up, reorder — branches on no host class. Every host answers eight
# things, each a plain method beside this include:
#
#   input_refusal          the synchronous refusal every door verb reads, or nil
#   input_kinds            what a caller may send as `kind`
#   admitted_input_fields  the command fields a caller may SUPPLY; the rest refuse by name
#   input_queue_limit      the caller-authored bound
#   hosts_turns?           whether a bound steer names a turn row
#   steer_binding          what `delivery_mode: steer` binds to: a turn, `:self`, or nil to queue
#   wake_drain(at: nil)    the kick every door verb sends after commit — now, or at the time a
#                          scheduled row is due (the create door's `deliver_at`)
#   note_activity          the activity stamp a door verb leaves, where the host keeps one
#
# And three answers about WHOSE work it hosts:
#
#   answering_user         the User the host's work is judged for and answered as: a conversation's
#                          stored answerer, a standalone loop's creator
#   declaring_profile      the Agent Profile whose standing declaration the host's work runs under —
#                          the answerer when it is an agent — or nil
#   bound_runner           the runner-kind executor this host's runner-tool calls are addressed to, or nil
#
# And one about who else may answer a turn here:
#
#   answerer_eligible?(u)  whether `u` may be named as a row's addressee: a conversation judges the
#                          create door's rule plus `full` on the row; a standalone loop admits no addressee
module InputHost
  extend ActiveSupport::Concern

  included do
    has_many :conversation_inputs, as: :host, dependent: :destroy
    # The runner binding: written at create (Executors::InitialRunner),
    # copied by a fork (Conversations::Fork), rewritten ONLY by
    # `bind_runner` below — the sanctioned value→value rebinding of
    # `runner_executor_id`.
    belongs_to :runner_executor, class_name: "TaskExecutor", optional: true
  end

  # THE ONE VERB that moves a host's binding, under the host row's own lock
  # — a conversation's lane lock, a standalone loop's own row — re-reading
  # the column before the write, so two handoffs serialize and the same id
  # is `:runner_unchanged` (idempotent by value, no receipt). Narrated
  # `runner_bound` on the host feed: the cursor is the ladder's last rank on
  # either host; `previous` is nil before any binding and after a reap (the
  # FK nullifies). The target was authorized by the caller
  # (Executors::Handoff) — this writes and narrates, nothing more.
  def bind_runner(executor, by:)
    with_lock do
      next :runner_unchanged if runner_executor_id == executor.id

      previous = runner_executor
      update!(runner_executor_id: executor.id)
      ConversationEvent::Append.call(host: self, items: [{
        type: "runner_bound",
        payload: {
          "executor_public_id" => executor.public_id,
          "previous_executor_public_id" => previous&.public_id,
          "by" => by.public_id,
        }.compact,
      }])
      :bound
    end
  end
end
