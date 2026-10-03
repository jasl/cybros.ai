module Rho
  class Daemon
    class Loops
      # Restoring and installing followers keeps the same host store and lineage.
      module Following
        # On the workspace-adopted edge: a finished host is forgotten, a live
        # one gets its follower and its gate back — which is where a settle
        # that happened while nobody was following is found.
        def readopt(credential, _workspace_public_id, credential_provider: nil)
          cached = store.rows
          rows = (cached + legacy_policies.rows.map { |raw| HostStore::Row.from_h(raw) })
            .uniq { |row| [row.host_type, row.host_public_id] }
          return if rows.empty?

          client = @wire.client(credential, credential_provider: credential_provider)
          rows.each do |row|
            workspace = client.workspace(row.workspace)
            host = row.host
            hosted = host.context(workspace)
            if host.settled?(hosted)
              forget(host)
              next
            end
            remember(host, workspace: row.workspace, live: row.live, turn: row.turn, loop: row.loop,
              runner: row.runner, answerer: row.answerer)
            row = restore_policy(host, hosted, live: row.live) if host.outlives_turn?
            readopt_row(row, host, hosted, workspace, @context)
            @log.info("loops.readopted", host: host.public_id, host_type: host.type,
              live: row.live, notes: row.notes.keys)
          rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden
            legacy_policies.complete(host.public_id) if host.outlives_turn?
            forget(host)
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError, Rho::StateError, KeyError => error
            @log.warn("loops.readopt_failed", host: row.host_public_id,
              error_class: error.class.name)
          end
        end

        # Best-effort by design: the host is already the kernel's, so a follow
        # failure must not fail the open. The caller first restores the
        # cache and durable policy; turn and loop then follow the feed.
        def adopt_run(host, hosted, body, gate: nil, loops: nil, turn: nil, loop: nil, about: @lineage.credentials)
          row = store.find(host.public_id)
          turn ||= row&.turn
          loop ||= row&.loop
          gate ||= follow_gate(loop || host.own_loop, row.notes, @context) if row && (loop || host.own_loop)
          fresh = nil
          run, adopted = @context.follow(about, host.public_id) do |realtime|
            fresh = HostRun.new(
              host: host, context: hosted, realtime: realtime,
              live: body["live"] != false, stream: body["stream"] != false,
              logger: @log, gate: gate, spawner: @context.method(:spawn), sleeper: @sleeper,
              loop_context: loops && ->(public_id) { loops.agent_loop(public_id) },
              turn: turn, loop: loop,
              on_turn: ->(run) { follow_turn(run, hosted) },
              on_runner_bound: ->(run, payload) { follow_runner_bound(run, payload) },
              # A park on a btw side is denied from here: the loop
              # context the deny goes through is the workspace's.
              on_attention: ->(run, attention, source_loop_public_id) { follow_attention(run, attention, loops, source_loop_public_id, hosted: hosted) },
              on_complete: ->(finished) { finished.host.outlives_turn? ? follow_settled_model(finished, loops, hosted) : forget(finished.host, retain_snapshot: true) },
              # The host ENDED under the follow: the kernel's `conversation_ended` item, or its 404 —
              # archived or deleted — forgotten here, as the readopt forgets one that is 404 at boot.
              on_ended: ->(ended) { forget(ended.host) },
              # THE CHILD EDGE: every spawned child new to the
              # listing gets the parent's record copied top-down, and is
              # told when its runner is elsewhere.
              on_children: ->(run, added) { @environments.adopt_children(run.host.public_id, added) }
            )
          end
          # Our own run back unadopted is the lineage refusing a dead `about`:
          # nobody follows it, so nobody is told.
          return nil if !adopted && run.equal?(fresh)

          run
        rescue StandardError => error
          @log.warn("loop_follow_not_started", host: host.public_id,
                    error_class: error.class.name)
          nil
        end

        private

          def install_gate(run, gate)
            return if gate.nil?

            run.gate = gate
            run.nudge
          end

          # THE ONE SITE the store learns a conversation's current turn and
          # backing loop: the follower's callback, on every move the feed
          # narrates — the open, and every `rho say` turn after it.
          def follow_turn(run, hosted)
            return unless run.host.outlives_turn?

            snapshot = run.snapshot
            row = follow_row(run, hosted)
            return if row.nil?

            remember(run.host, workspace: row.workspace, live: row.live, turn: snapshot.turn, loop: snapshot.loop)
            if run.gate.nil? && snapshot.loop
              install_gate(run, follow_gate(snapshot.loop, row.notes, @context))
            end
          end

          # THE SPINE'S MODEL, REMEMBERED AT TURN SETTLE: the loop
          # projection's `turn.model` — the spine tail, the stated place the
          # kernel carries the model a turn's main line ran on — is where the
          # turn ended up; when it differs from the row's, the row takes it,
          # so the next `say` rides it. A spine round the answerer's fallback
          # re-ran after a provider declined it continues there, rather than
          # sending the declining model the same context each turn. Never off
          # a task's `model_change`: a compose member's switch is that
          # member's and never moves the main line. The kernel keeps no
          # routing policy — rho persists this changed preference in the
          # conversation's Store. Unchanged models cause no policy IO.
          def follow_settled_model(run, loops, hosted)
            return if loops.nil?

            loop_public_id = run.snapshot.loop
            row = follow_row(run, hosted)
            return if row.nil? || loop_public_id.nil?

            model = loops.agent_loop(loop_public_id).fetch.turn&.model_ref
            return if model.nil? || model == row.model

            save_policy(run.host, hosted, model: model)
            @log.info("host.model_followed", host: run.public_id, from: row.model, to: model)
          rescue CybrosAgent::Error, Rho::StateError => error
            @log.warn("host.model_unread", host: run.public_id, agent_loop: loop_public_id,
              error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
          end

          # A remembered row followed again — at boot, or before a `say` on a
          # host whose run ended — with the gate its notes describe, bound to
          # the loop the row knew.
          def readopt_row(row, host, hosted, workspace, _ctx)
            adopt_run(host, hosted, { "live" => row.live }, loops: workspace.agent_loops,
              turn: row.turn, loop: row.loop)
          end
      end
    end
  end
end
