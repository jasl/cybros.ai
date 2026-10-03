module Conversations
  module Inputs
    # The host's field contract at the boundary: a command field the host does
    # not admit, supplied non-nil, is refused by name — the record carries one
    # `not_admitted` error per field, never a silent default.
    module Admission
      # The command members that address the verb rather than describe the row.
      PLUMBING = %i[host acting_user input_public_id].freeze
      # The kernel's privileges: no door admits them, no caller can
      # supply them — the controllers never build a command carrying
      # one, so nothing here needs refusing.
      KERNEL_STAMPS = %i[origin sender_conversation_public_id agent_loop_public_id task_key delegation callback_result].freeze

      def self.refusal(host:, command:)
        supplied = command.to_h.compact.keys - PLUMBING - KERNEL_STAMPS
        refused = supplied - host.admitted_input_fields
        return nil if refused.empty?

        record = host.conversation_inputs.new
        refused.each { |field| record.errors.add(field, :not_admitted) }
        Outcome.invalid(record)
      end
    end
  end
end
