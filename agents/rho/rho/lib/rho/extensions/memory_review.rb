require "async/semaphore"
require_relative "../memory_review"

module Rho
  module Extensions
    module MemoryReview
      NAME = Rho::MemoryReview::NAMESPACE

      def self.register(api)
        observer = Observer.new(resources: api.resources, log: api.log)
        api.resources.own(on_retire: true) { observer.close }
        api.on(:turn_settled) { |settlement, ctx| observer.settled(settlement, ctx) }
        Routes.register(api, observer: observer)
      end

      # One registration serializes its background observations. A second
      # source arriving while submission yields must see the first pending
      # snapshot and consume its position, rather than lose that fact on CAS.
      class Observer
        Subscription = Data.define(:follower, :token)

        def initialize(resources:, log:)
          @resources, @log = resources, log
          @serial = Async::Semaphore.new(1)
          @subscriptions = {}
          @closed = false
        end

        def settled(settlement, ctx)
          @serial.acquire do
            ctx.member_plane(workspace_public_id: settlement.workspace_public_id) do |client, workspace_public_id, about|
              workspace = client.workspace(workspace_public_id)
              source = Rho::MemoryReview.source_for(workspace: workspace, conversation_public_id: settlement.conversation_public_id)
              service(ctx, workspace, source, about).settled(settlement)
            end
          end
        end

        def service(ctx, workspace, conversation_public_id, about)
          follow = ->(side_id) { follow(ctx, workspace, conversation_public_id, about, side_id) }
          forget = ->(side_id) do
            unwatch(side_id)
            ctx.forget(Rho::Host::Conversation.new(public_id: side_id))
          end
          Rho::MemoryReview.new(workspace: workspace, conversation_public_id: conversation_public_id, follow: follow, forget: forget)
        end

        def close
          @closed = true
          @subscriptions.keys.each { |side_id| unwatch(side_id) }
        end

        private

          # Reuse the ordinary follower for completion, replay and blocked
          # input recovery. The purpose note excludes this side from the interactive side.
          def follow(ctx, workspace, source_id, about, side_id)
            return if @closed

            host = Rho::Host::Conversation.new(public_id: side_id)
            hosted = workspace.conversation(side_id)
            HostPolicy.new(store: -> { hosted.store_entries }, owner_public_id: ctx.own_user_public_id,
              host_public_id: side_id).replace(notes: { NAME => { "parent" => source_id } })
            follower = ctx.adopt_follower(about, host, hosted, { "live" => false, "stream" => false }, runs: workspace.runs)
            return if follower.nil?

            unless @subscriptions[side_id]&.follower.equal?(follower)
              unwatch(side_id)
              token = follower.listen do |event|
                if event.type == "input_blocked" && event.payload["blocked_reason"] != "run_held"
                  resume(ctx, workspace, source_id, about)
                end
              end
              @subscriptions[side_id] = Subscription.new(follower: follower, token: token)
            end
            # Subscribe before inspecting the snapshot: a block that arrived
            # during attachment is already durable even if its wake was missed.
            resume(ctx, workspace, source_id, about) if follower.snapshot.blocked
          end

          def resume(ctx, workspace, source_id, about)
            return if @closed

            lease = @resources.acquire
            ctx.spawn do
              begin
                @serial.acquire { service(ctx, workspace, source_id, about).resume }
              rescue StandardError => error
                @log&.warn("memory_review_recovery_failed", error_class: error.class.name)
              ensure
                lease.release
              end
            end
          rescue StandardError
            lease&.release
            raise
          end

          def unwatch(side_id)
            subscription = @subscriptions.delete(side_id)
            subscription.follower.forget(subscription.token) if subscription
          end
      end
    end
  end
end

require_relative "memory_review/routes"
