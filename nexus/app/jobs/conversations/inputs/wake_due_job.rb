# Each hop advances past retained rows at the first hop's fixed cutoff.
# A lost continuation is recovered by the next minute's fresh scan.
class Conversations::Inputs::WakeDueJob < ApplicationJob
  def perform(cutoff = nil, after_at = nil, after_id = 0)
    result = Conversations::Inputs::WakeDue.call(cutoff: cutoff, after_at: after_at, after_id: after_id)
    self.class.perform_later(*result.cursor) if result.more?
  end
end
