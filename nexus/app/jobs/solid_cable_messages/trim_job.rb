# Cable messages are the highest-volume durable rows here: a streaming
# turn writes ten a second, and the gem's own trim stops after one batch of
# 100. This continues while there is more, under a pass bound so it never starves the queue.
class SolidCableMessages::TrimJob < ApplicationJob
  # THE ARITHMETIC, so the number is read against its producers and moved
  # on a measured backlog, never by feel: every minute this job reclaims at
  # most MAX_PASSES × `trim_batch_size` (5000, cable.yml) = 100,000 rows. A
  # streaming turn writes ~600 rows/min; the progress door admits one frame
  # per key per `Executors::Progress::MIN_INTERVAL_MS` (250 ms) — at most 4
  # frames/s = 240 rows/min per key beside it — so ~400 keys posting at the
  # full rate are the day's reclaim; past that the cable database grows
  # until `message_retention` (a day) and the primary never. Not re-sized
  # here: the first four-worlds run that reports a trimmable backlog is
  # what moves it.
  MAX_PASSES = 20

  def perform(pass = 1)
    SolidCable::TrimJob.perform_now
    return if pass >= MAX_PASSES

    self.class.perform_later(pass + 1) if SolidCable::Message.trimmable.exists?
  end
end
