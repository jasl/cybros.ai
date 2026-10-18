# Model deltas and executor progress can outpace the gem's single trim batch.
# Separate continuation jobs let the queue interleave other work between passes.
class SolidCableMessages::TrimJob < ApplicationJob
  # With cable.yml's 5,000-row batch and the one-minute schedule, this is a
  # 150,000-row budget, not a measured throughput ceiling. At 2,400 rows/s,
  # test/benchmarks/progress_cable_capacity.rb measured the former 20-pass
  # budget leaving about 44,000 more expired rows each minute. Thirty passes
  # budget for that arrival rate without changing batch size or cadence.
  MAX_PASSES = 30

  def perform(pass = 1)
    SolidCable::TrimJob.perform_now
    return if pass >= MAX_PASSES

    self.class.perform_later(pass + 1) if SolidCable::Message.trimmable.exists?
  end
end
