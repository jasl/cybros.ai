module CybrosAgent
  module Realtime
    # THE ADAPTER BETWEEN A SOCKET AND A FEED, and it exists because of a
    # lifetime: `KernelFeed` asks for a subscription on every connect and drops
    # it on every loss, so what it holds has to be disposable.
    #
    # ONE CLIENT MAY CARRY MANY LOGICAL SUBSCRIPTIONS. ActionCable already
    # multiplexes them; the owning daemon supplies that shared client and the
    # Client serializes only the lazy handshake. A lost cable wakes every feed,
    # and each independently re-drains its own durable window before subscribing
    # again, so shared transport never becomes shared correctness state.
    class FeedSubscription
      # A `subscribe:` callable for KernelFeed, bound to one channel. Each
      # call opens one logical subscription on the supplied client.
      # THE TWO TRANSPORTS MUST DELIVER THE SAME TYPE. A feed orders, dedupes
      # and gap-detects across replay and socket, so the moment it can tell
      # which one an item came from, every comparison it makes is conditional
      # on something it should not be able to see. `event` is where a raw
      # ActionCable frame becomes the same typed item the replay page yields —
      # the Client stays payload-blind, and the resource's own context, which
      # knows the projection, supplies it.
      #
      # A frame the mapper answers nil for is DROPPED here rather than
      # delivered as nothing.
      def self.opener(client:, channel:, params: {}, event:,
                      timeout: Client::DEFAULT_SUBSCRIBE_TIMEOUT)
        -> { open(client: client, channel: channel, params: params, event: event, timeout: timeout) }
      end

      def self.open(client:, channel:, params: {}, event:,
                    timeout: Client::DEFAULT_SUBSCRIBE_TIMEOUT)
        client.connect_for_feed
        new(
          event: event,
          subscription: client.subscribe(channel: channel, params: params, timeout: timeout)
        )
      end

      def initialize(subscription:, event:)
        @subscription = subscription
        @event = event
      end

      def each
        @subscription.each do |message|
          item = @event.call(message)
          yield item unless item.nil?
        end
      end

      # Ends only this logical stream. The daemon owns the shared connection
      # and closes it when the lineage or daemon ends.
      def unsubscribe
        @subscription.unsubscribe
        nil
      end
    end
  end
end
