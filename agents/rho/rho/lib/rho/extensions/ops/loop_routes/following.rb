module Rho
  module Extensions
    module Ops
      module LoopRoutes
        class << self
          # The events as they land, for a page that wants a round's text as
          # it arrives (`rho watch` polls). Only a host this daemon follows
          # can be followed in turn — the events come from its follower;
          # `rho attach` first. The stream ends with the TURN: a
          # conversation's follow outlives it, a reader's does not.
          #
          # ENDING TAKES BOTH FEEDS. `turn_settled?` is the
          # EVENTS feed's word and the settle a person READS lands on the
          # transcript one, milliseconds later; closing on the first alone is
          # why a live turn could end here with nothing printed while
          # `rho watch` showed the whole reply. So every close asks for both,
          # and `tend_stream` bounds the wait.
          def stream(request, ctx)
            public_id = ControlServer.query(request)["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            run = ctx.run(public_id)
            return Rho::Daemon::Refusal.not_followed(public_id, lane: :loop, hint: "attach it first") unless run&.host?

            stream = Rho::LoopStream.new(public_id: public_id, log: ctx.log)
            token = run.listen do |event|
              stream.deliver(event.type, event.payload)
              # A settled turn whose text has settled too ends the stream
              # now, not at the next heartbeat — and the settle's own frames
              # come through this very handler, so the last word printed is
              # the one that closes it.
              reason = reader_end(run)
              stream.close(reason) if reason
            end
            # The snapshot first, so a reader joining a loop parked for hours
            # renders something immediately.
            stream.deliver("snapshot", run.snapshot.to_h)
            if (reason = reader_end(run))
              # Nothing more will come: hand over the snapshot and end.
              run.forget(token)
              stream.close(reason)
            else
              ctx.spawn { tend_stream(run, stream, token) }
            end
            stream.response
          end

          # The one other word `attach` takes.
          CONVERSATION_ARM = "conversation".freeze

          # How a person picks up a loop this daemon did not place (after a
          # restart, or on a second machine); remembered so the next restart
          # keeps it. The feed followed is the loop's HOST's — its own, or
          # the conversation whose turn it backs — never opened blind. THE
          # CONVERSATION ARM: with
          # `host_type: "conversation"` the id names a conversation — a row
          # the bounded store forgot, a thread an editor reopens — read
          # through the kernel's own door first (an unknown id is its 404),
          # followed on its own feed, remembered, no loop fetched.
          def attach(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, about, body|
              public_id = body["public_id"].to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

              host_type = body["host_type"]
              unless host_type.nil? || host_type == CONVERSATION_ARM
                next Rho::Daemon::Refusal.malformed("host_type must be #{CONVERSATION_ARM}, or absent for a loop")
              end
              next attach_conversation(ctx, client, workspace_public_id, about, public_id, body) if host_type

              loops = ctx.loops_for(client, workspace_public_id)
              agent_loop = loops.agent_loop(public_id).fetch
              if CybrosAgent::Api::LOOP_TERMINAL_STATUSES.include?(agent_loop.status)
                next Rho::Daemon::Refusal.new(status: 409, code: "loop_terminal",
                  message: "#{agent_loop.status} — there is nothing left to follow")
              end

              host = Rho::Host.resolve(public_id, rows: [], fetch_loop: ->(_id) { agent_loop })
              hosted = host.context(client.workspace(workspace_public_id))
              run = follow(ctx, about, host, hosted, loops: loops, live: body["live"] != false,
                stream: body["stream"] != false)
              [200, { loop: HostRun.loop_projection(agent_loop), run: run&.snapshot&.to_h }.compact]
            end
          end

          def attach_conversation(ctx, client, workspace_public_id, about, public_id, body)
            workspace = client.workspace(workspace_public_id)
            host = Rho::Host::Conversation.new(public_id: public_id)
            hosted = host.context(workspace)
            document = hosted.fetch
            run = follow(ctx, about, host, hosted, loops: workspace.agent_loops,
              live: body["live"] != false, stream: body["stream"] != false, document: document)
            [200, { conversation: { public_id: public_id }, run: run&.snapshot&.to_h }.compact]
          end

          private

            def hosts(ctx) = ctx.runs.select(&:host?)

            # The followed set as snapshots. SIDE hosts (`rho.side` in the store's notes) are hidden by default and listed alone under
            # `side=1`, each with its parent — a UI may hide them, and the
            # terminal does.
            def snapshots(ctx, side: false)
              hosts(ctx).filter_map do |run|
                note = ctx.notes(run.public_id)[SIDE_NOTE]
                next if note.nil? != !side

                row = run.snapshot.to_h
                note ? row.merge(side: { parent: note["parent"] }) : row
              end
            end

            # One fiber per reader: it ends the stream when the turn does, and
            # the heartbeat is how a dead peer is discovered on a parked loop.
            #
            # BOTH FEEDS, OR THE GRACE. The heartbeat keeps its own cadence,
            # and the settle is polled between beats — because a settle with
            # no remainder fans no frame at all, so the listener that would
            # otherwise close the stream is never called. Past the grace the
            # reader is ended anyway: a settle that is not coming must not
            # hold a terminal open.
            #
            # `grace`/`poll` are arguments rather than reads of the constant
            # for one reason: that fallback is what a test has to be able to
            # see without waiting five real seconds for it.
            def tend_stream(run, stream, token,
                            grace: Rho::LoopStream::SETTLE_GRACE_SECONDS,
                            poll: Rho::LoopStream::SETTLE_POLL_SECONDS)
              settled_at = nil
              next_beat = monotonic + Rho::LoopStream::HEARTBEAT_SECONDS
              loop do
                sleep poll
                break unless stream.open?

                if run.stopped?
                  stream.close(reader_end(run))
                  break
                end

                if monotonic >= next_beat
                  break unless stream.heartbeat

                  next_beat = monotonic + Rho::LoopStream::HEARTBEAT_SECONDS
                end
                next unless run.turn_settled?

                settled_at ||= monotonic
                if reader_settled?(run) || (monotonic - settled_at) >= grace
                  stream.close("turn_settled")
                  break
                end
              end
            ensure
              run.forget(token)
              stream.close
            end

            # THE READER'S END, which is both halves of the host's: where
            # the turn got to, and that what it said has settled.
            def reader_settled?(run) = run.turn_settled? && run.transcript_settled?

            def reader_end(run)
              return "turn_settled" if reader_settled?(run)

              "host_ended" if run.stopped?
            end

            def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            # Through the one door, which starts it; a host already followed
            # answers its standing run, one the lineage refused answers nil.
            # A turn's terminal ends a LOOP host and forgets its row; a
            # CONVERSATION outlives its turns (`Loops#adopt_run`'s rule) — a fresh follower replays the feed from
            # the start, so the last turn's settle lands moments after the
            # attach, and forgetting the row on it left `say` reading "not
            # following" right after a successful `attach --conversation`.
            def follow(ctx, about, host, hosted, loops:, live:, stream: true, document: nil)
              # Remember before replay starts, so a selected candidate's
              # current identity is never overwritten by the attach input.
              ctx.adopt_run(about, host, hosted, { "live" => live, "stream" => stream }, loops: loops, document: document)
            end
        end
      end
    end
  end
end
