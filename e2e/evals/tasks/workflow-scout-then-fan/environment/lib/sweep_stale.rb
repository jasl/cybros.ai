# Drops sessions nobody touched within the time-to-live.
class SweepStale
  def initialize(sessions, ttl:)
    @sessions = sessions
    @ttl = ttl
  end

  def call(now)
    fresh, stale = @sessions.partition { |session| now - session.fetch(:touched_at) < @ttl }
    @sessions = fresh
    stale.size
  end
end
