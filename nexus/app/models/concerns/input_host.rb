# Shared input queue and optional default execution environment for a host.
module InputHost
  extend ActiveSupport::Concern

  included do
    has_many :conversation_inputs, as: :host, dependent: :destroy
    belongs_to :default_runner_executor, class_name: "TaskExecutor", optional: true
  end

  def set_default_runner(executor, by:)
    with_lock do
      next :unchanged if default_runner_executor_id == executor&.id

      previous = default_runner_executor
      update!(default_runner_executor_id: executor&.id)
      ConversationEvent::Append.call(host: self, items: [{
        type: "default_runner_changed",
        payload: {
          "executor_public_id" => executor&.public_id,
          "previous_executor_public_id" => previous&.public_id,
          "by" => by.public_id,
        },
      }])
      :changed
    end
  end
end
