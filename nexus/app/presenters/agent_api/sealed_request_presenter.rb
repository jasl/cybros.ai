module AgentAPI
  # THE INSPECTION READ: exactly what was sealed for a model — the request
  # body's entries in position order, VERBATIM, and the invocation's
  # request_options (the generation bag plus the wire facts: tools,
  # instructions). Two keys; nothing derived, nothing re-assembled — the
  # sealed body is the only faithful record.
  class SealedRequestPresenter
    class << self
      def call(invocation)
        {
          request: {
            entries: ModelRequests::InputSource.accepted_entry_payloads(invocation),
            request_options: invocation.request_options,
          },
        }
      end
    end
  end
end
