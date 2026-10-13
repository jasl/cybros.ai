class Users::StopAgentWorkJob < ApplicationJob
  def perform(user_id = nil, options = {})
    result = Users::StopAgentWork.call(user_id:, **options)
    self.class.perform_later(user_id, options.merge(result.cursor)) if result.more?
  end
end
