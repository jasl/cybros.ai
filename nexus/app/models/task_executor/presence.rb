# THE PRESENCE MARKS, written at the executor socket's edges and never a
# gate. `mark_connected` is a WHOLE replacement — a newer connection
# overwrites an older one's mark; the subscription was verified at the
# current epoch. `clear_connected` clears iff the stored id is THIS
# connection's (one guarded UPDATE, GuardedStamp's idiom), so an older
# connection's close never erases a newer one's mark during reconnect
# overlap. Which of the marks are LIVE is the database's answer — a mark is
# online iff the `nexus_servers` row it names is (`Nexus::Presence`). Beside
# them the coarse last-seen sample.
module TaskExecutor::Presence
  def mark_connected(connection_id)
    update_columns(presence_connection_id: connection_id, presence_server_id: NexusServer.boot_id,
      connected_at: Time.current)
  end

  def clear_connected(connection_id)
    self.class.where(id: id, presence_connection_id: connection_id)
      .update_all(presence_connection_id: nil, presence_server_id: nil, connected_at: nil)
    self
  end

  # Coarse observability, never an authentication input: one contender
  # refreshes per LAST_SEEN_REFRESH_RATE without a row lock.
  def refresh_last_seen_at(expected_epoch:)
    stamped_at = Time.current
    cutoff = stamped_at - TaskExecutor::LAST_SEEN_REFRESH_RATE
    return self if last_seen_at.present? && last_seen_at > cutoff

    current_epoch = self.class.where(credential_epoch: expected_epoch)
    refreshable = current_epoch.where(last_seen_at: nil).or(current_epoch.where(last_seen_at: ..cutoff))
    stamp_if(refreshable, :last_seen_at, at: stamped_at)
  end
end
