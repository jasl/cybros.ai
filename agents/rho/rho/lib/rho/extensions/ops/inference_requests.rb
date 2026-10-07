module Rho
  module Extensions
    module Ops
      # Placing a run and following it are one verb: the answer is a stream
      # of durable events, and a caller handed only an id would rebuild the
      # follower this daemon has. No CLI verb.
      module InferenceRequests
        # Optional create controls omit nil, while an explicit false switch
        # stays part of the caller's selection and idempotency envelope.
        OPTIONAL_CREATE_MEMBERS = %i[
          configuration reasoning_effort reasoning_enabled upload_public_ids billing_subject
        ].freeze

        class << self
          def register(api)
            api.register_route("POST", "/inference_requests") { |request, ctx| start(request, ctx) }
            # A list, not an addressed read: a handful of runs at a time.
            api.register_route("GET", "/inference_requests") { |_request, ctx| [200, { inference_requests: snapshots(ctx) }] }
            api.register_route("POST", "/inference_requests/subscribe") { |request, ctx| set_live(request, ctx, true) }
            api.register_route("POST", "/inference_requests/unsubscribe") { |request, ctx| set_live(request, ctx, false) }
          end

          # Creation is one bounded request on the handler's fiber; the
          # following outlives it on the reactor, read from `GET /inference_requests`.
          def start(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, about, body|
              lane = client.workspace(workspace_public_id).inference_requests
              accepted = lane.create(**create_fields(body))
              # Create returning is the irreversible checkpoint: the run may
              # bill, so a superseded lineage still answers the locator
              # without installing a dead run into its replacement.
              run, = adopt(ctx, about, lane, accepted.public_id, body)
              [202, { inference_request: run.snapshot.to_h }]
            end
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          # `live` false keeps only the lifecycle subscription, so terminality
          # stays prompt while output deltas nobody reads stay off the shared socket.
          def adopt(ctx, about, lane, public_id, body)
            ctx.follow(about, public_id) do |realtime|
              InferenceRequestRun.new(inference_requests: lane, public_id: public_id, realtime: realtime,
                live: body["live"] != false, logger: ctx.log)
            end
          end

          def snapshots(ctx) = ctx.followers.select(&:inference_request?).map { |run| run.snapshot.to_h }

          # `changed` is how a caller tells "I attached it" from "it already
          # was", which matters to a client reconciling focus it may have
          # lost track of.
          def set_live(request, ctx, live)
            body = ControlServer.json_body(request)
            public_id = body.fetch("public_id").to_s
            run = ctx.follower(public_id)
            return Rho::Daemon::Refusal.not_followed(public_id, lane: :inference_request) unless run&.inference_request?

            changed = live ? run.attach_socket : run.detach_socket
            [200, { inference_request: run.snapshot.to_h, changed: changed }]
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          private

            # The caller's own key, never one this daemon invents: a retry the
            # caller cannot recognize is how one prompt becomes two bills.
            # Every member the API accepts crosses; the bytes never touch this daemon.
            def create_fields(body)
              fields = {
                workload: body["workload"] || "text_generation",
                model: body.fetch("model"),
                input: body.fetch("input"),
                idempotency_key: body.fetch("idempotency_key"),
              }
              OPTIONAL_CREATE_MEMBERS.each do |member|
                value = body[member.to_s]
                fields[member] = value unless value.nil?
              end
              fields
            end
        end
      end
    end
  end
end
