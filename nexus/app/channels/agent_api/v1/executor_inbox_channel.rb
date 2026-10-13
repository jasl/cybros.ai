# THE LATENCY CHANNEL of the executor boundary, ONE per executor:
# it carries a NUDGE and never work — `work_available` to the addressee,
# `work_canceled` to the claimant — and the HTTP inbox is the truth,
# level-triggered, complete, and enough on its own, so a dropped
# subscription, a missed frame, or an executor that was simply not
# connected costs latency and never a task. No params: the credential
# names the address. The stream carries no epoch — the subscription dies
# with the credential, which the connection's recheck enforces.
#
# PRESENCE RIDES THIS SUBSCRIPTION'S EDGES: `subscribed` marks
# the executor's row with the connection's id, `unsubscribed` clears the
# mark iff it is still this connection's, and the `pong` action keeps the
# socket honest against the connection's expectation. The HTTP inbox stays
# the truth — nothing here is a gate.
class AgentAPI::V1::ExecutorInboxChannel < ApplicationCable::Channel
  def self.stream_name(...) = Nexus::RealtimeStreams.executor_inbox(...)

  def subscribed
    token = connection.verified_executor_token
    return reject if token.nil?

    @executor = token.task_executor
    stream_from self.class.stream_name(@executor.public_id)
    @executor.mark_connected(connection.presence_id)
    connection.expect_pongs
  end

  # The row this subscription marked is the row it clears — by the id it
  # wrote, never by the credential's epoch, so a subscription fenced while
  # open still clears its own mark and never a newer connection's.
  def unsubscribed
    connection.stop_expecting_pongs
    @executor&.clear_connected(connection.presence_id)
  end

  def pong
    connection.pong
  end
end
