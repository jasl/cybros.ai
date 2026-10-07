require "rho/gateway/commands"

module Rho
  module IngressTelegram
    # Telegram owns presentation and reply-to-message handling; slash controls
    # are dispatched by the in-process gateway.
    class Commands < Rho::Gateway::Commands
      HELP = "Send a message to start. In groups, mention me or reply to your task's receipt or answer.\n" \
        "#{Rho::Gateway::Commands::HELP}\nYou can also reply to a question message with your answer.\n".freeze
      MENU = DEFINITIONS.map { |command| { command: command.name, description: command.description } }.freeze

      def call(update, name, argument)
        if %w[side btw].include?(name)
          @runtime.reply(update, "Side conversations are not available in Telegram. Continue in this chat or use /new.")
        else
          super
        end
      end

      def answer_reply(update)
        document = @runtime.state.read
        question = document.fetch("questions").find do |_id, row|
          route = document.fetch("routes")[row.fetch("route_key")]
          Array(row["message_ids"]).include?(update.reply_id) && row.fetch("kind") == "ask" && !row["resolved"] &&
            route && route.fetch("chat_id") == update.chat_id && route["topic_id"] == update.topic_id
        end
        if question
          call(update, "answer", "#{question.first} #{update.text}")
          true
        elsif @runtime.question_reply_id(update)
          # Telegram retains the original bot message after our receipt is pruned.
          # An answer to that retired question is never a fresh model request.
          @runtime.reply(update, "That request is no longer available in this chat.")
          true
        else
          false
        end
      end
    end
  end
end
