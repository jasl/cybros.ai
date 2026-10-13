require "rho/gateway/delivery_time"

module Rho
  module IngressTelegram
    module ReminderWorkflow
      def remind(update, expression:, text:)
        if update.media || update.unsupported_media?
          reply(update, "Reminders accept text only. Send attachments as a normal queued message.")
          return
        end

        at = saved_delivery_time(expression)
        submit(update, text: "Please remind me now: #{text}", deliver_at: at)
      end

      private

        def saved_delivery_time(expression)
          pending = @state.read.fetch("pending_update")
          return pending.fetch("deliver_at") if pending["deliver_at"]

          at = Rho::Gateway::DeliveryTime.resolve(expression, now: @clock.call)
          @state.change { |document| document.fetch("pending_update")["deliver_at"] = at }
          at
        end
    end
  end
end
