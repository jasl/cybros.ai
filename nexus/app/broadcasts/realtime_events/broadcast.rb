module RealtimeEvents
  # One publish seam for the cable mirrors; the rescue is load-bearing,
  # since a broadcast failure must never fail the committed append. Lifecycle
  # items go out twice so a consumer not reading the output still hears the ending.
  class Broadcast
    # Where a resource is, as opposed to what it is producing — plus the one
    # item that is a call to act, and the host's own end (a follower
    # narrowed to lifecycle must still hear that nothing further comes).
    # One list for both hosts of the hosted plane.
    HOSTED_LIFECYCLE_TYPES = %w[turn_status attention_required conversation_ended].freeze
    LIFECYCLE_TYPES = {
      "inference_request" => %w[run_status result].freeze,
      "conversation" => HOSTED_LIFECYCLE_TYPES,
      "run" => HOSTED_LIFECYCLE_TYPES,
    }.freeze

    def self.call(resource_type:, resource_public_id:, event_item:)
      stream = ->(feed) { Nexus::RealtimeStreams.resource(resource_type, resource_public_id, feed) }
      ActionCable.server.broadcast(stream.call("events"), { event: event_item })
      lifecycle_types = LIFECYCLE_TYPES.fetch(resource_type, [])
      return unless lifecycle_types.include?(event_item.fetch(:type))

      ActionCable.server.broadcast(stream.call("lifecycle"), { event: event_item })
    rescue StandardError => error
      report(error, resource_type, resource_public_id)
    end

    # THE EPHEMERAL HALF: a frame on the host's `progress` feed — an
    # executor's (`Executors::Progress`) today, the kernel's own narration
    # when 3.2 lands — under the envelope `{frame}`, never `{event}`: a
    # frame is not an item, mirrors no row, replays nowhere, and a
    # consumer that reads `event` never sees one. The same rescue as the
    # mirror's: a cable that is down costs a frame, never the work.
    def self.frame(resource_type:, resource_public_id:, frame:)
      ActionCable.server.broadcast(
        Nexus::RealtimeStreams.resource(resource_type, resource_public_id, "progress"), { frame: frame }
      )
    rescue StandardError => error
      report(error, resource_type, resource_public_id)
    end

    def self.report(error, resource_type, resource_public_id)
      Rails.error.report(error, handled: true,
        context: { event: "realtime_event_broadcast_failed",
                   resource_type: resource_type, resource_public_id: resource_public_id })
      nil
    end
    private_class_method :report
  end
end
