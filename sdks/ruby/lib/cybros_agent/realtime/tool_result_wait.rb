module CybrosAgent
  module Realtime
    # Terminal tool events only wake the authoritative task read. The timed wait
    # remains available when a socket is silent, disconnected or refused.
    class ToolResultWait
      def self.open(context, realtime)
        scope = Async::Task.current? || raise(CybrosAgent::Error, "realtime result waiting requires an Async reactor")
        wake = Thread::SizedQueue.new(1)
        signal = lambda do
          wake.push(true, true)
        rescue ThreadError
          # One pending read covers every event already received.
        end
        opener = context.realtime_opener(realtime, items: "events")
        follower = nil
        failure = nil
        listening = true
        waiter = lambda do |seconds|
          if listening && (follower.nil? || follower.finished?)
            follower = scope.async do
              subscription = opener.call
              # Re-read after confirmation: completion may have happened between
              # the initial task read and the subscription becoming live.
              signal.call
              subscription.each do |event|
                next unless event.type == "task_status" && event.payload["task_key"] == Api::RunContext::TOOL_CALL_TASK_KEY
                next unless Api::TASK_TERMINAL_STATUSES.include?(event.payload["status"])

                signal.call
                break
              end
              listening = false
            rescue ConnectionLostError, TransportError
              # A lost live stream gets an immediate task read. Failed opens
              # retry on the existing poll, so connection failure cannot spin.
              signal.call if subscription
            rescue CybrosAgent::Error, ArgumentError
              # A shared client can already have this subscription (ArgumentError).
              # REST owns the result and will surface any loss of authority.
              listening = false
            rescue StandardError => error
              failure = error
              signal.call
            ensure
              subscription&.unsubscribe
            end
          end
          wake.pop(timeout: seconds)
          raise failure if failure
        end
        yield waiter
      ensure
        follower&.stop
      end
    end
  end
end
