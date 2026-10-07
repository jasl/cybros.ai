module Rho
  class Daemon
    class HostFollowers
      # Restoring and installing followers keeps the same host store and lineage.
      module Following
        # On the workspace-adopted edge: a finished host is forgotten, a live
        # one gets its follower and its gate back — which is where a settle
        # that happened while nobody was following is found.
        def readopt(credential, _workspace_public_id, credential_provider: nil)
          rows = store.rows
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
            remember(host, workspace: row.workspace, live: row.live, turn: row.turn, run_public_id: row.run_public_id,
              runner: row.runner, answerer: row.answerer)
            row = restore_policy(host, hosted, live: row.live) if host.outlives_turn?
            readopt_row(row, host, hosted, workspace, @context)
            @log.info("runs.readopted", host: host.public_id, host_type: host.type,
              live: row.live, notes: row.notes.keys)
          rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden
            forget(host)
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError, Rho::StateError, KeyError => error
            @log.warn("runs.readopt_failed", host: row.host_public_id,
              error_class: error.class.name)
          end
        end

        # Best-effort by design: the host is already the kernel's, so a follow
        # failure must not fail the open. The caller first restores the
        # cache and durable policy; turn and run then follow the feed.
        def adopt_follower(host, hosted, body, gate: nil, runs: nil, turn: nil, run_public_id: nil, about: @lineage.credentials)
          row = store.find(host.public_id)
          turn ||= row&.turn
          run_public_id ||= row&.run_public_id
          gate ||= follow_gate(run_public_id || host.own_run, row.notes, @context) if row && (run_public_id || host.own_run)
          fresh = nil
          run, adopted = @context.follow(about, host.public_id) do |realtime|
            fresh = HostFollower.new(
              host: host, context: hosted, realtime: realtime,
              live: body["live"] != false, stream: body["stream"] != false,
              logger: @log, gate: gate, spawner: @context.method(:spawn), sleeper: @sleeper,
              run_context: runs && ->(public_id) { runs.run(public_id) },
              turn: turn, run_public_id: run_public_id,
              on_turn: ->(run) { follow_turn(run, hosted) },
              on_default_runner_changed: ->(run, payload) { follow_default_runner_changed(run, payload) },
              on_attention: ->(run, attention, source_run_public_id) { follow_attention(run, attention, runs, source_run_public_id, hosted: hosted) },
              on_complete: ->(finished) { finished.host.outlives_turn? ? follow_completed(finished, runs, hosted) : forget(finished.host, retain_snapshot: true) },
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
          @log.warn("run_follow_not_started", host: host.public_id,
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
          # backing run: the follower's callback, on every move the feed
          # narrates — the open, and every `rho say` turn after it.
          def follow_turn(run, hosted)
            return unless run.host.outlives_turn?

            snapshot = run.snapshot
            row = follow_row(run, hosted)
            return if row.nil?

            remember(run.host, workspace: row.workspace, live: row.live, turn: snapshot.turn, run_public_id: snapshot.run_public_id)
            if run.gate.nil? && snapshot.run_public_id
              install_gate(run, follow_gate(snapshot.run_public_id, row.notes, @context))
            end
          end

          # THE MAINLINE'S MODEL, REMEMBERED AT TURN SETTLE: the run
          # projection's `turn.model` — the mainline tail, the stated place the
          # kernel carries the model a turn's main line ran on — is where the
          # turn ended up; when it differs from the row's, the row takes it,
          # so the next `say` rides it. A mainline round the answerer's fallback
          # re-ran after a provider declined it continues there, rather than
          # sending the declining model the same context each turn. Never off
          # a task's `model_change`: a task member's switch is that
          # member's and never moves the main line. The kernel keeps no
          # routing policy — rho persists this changed preference in the
          # conversation's Store. Unchanged models cause no policy IO.
          def follow_settled_model(run, runs, hosted)
            return if runs.nil?

            run_public_id = run.snapshot.run_public_id
            row = follow_row(run, hosted)
            return if row.nil? || run_public_id.nil?

            model = runs.run(run_public_id).fetch.turn&.model_ref
            return if model.nil? || model == row.model

            save_policy(run.host, hosted, model: model)
            @log.info("host.model_followed", host: run.public_id, from: row.model, to: model)
          rescue CybrosAgent::Error, Rho::StateError => error
            @log.warn("host.model_unread", host: run.public_id, run: run_public_id,
              error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
          end

          # A remembered row followed again — at boot, or before a `say` on a
          # host whose run ended — with the gate its notes describe, bound to
          # the run the row knew.
          def readopt_row(row, host, hosted, workspace, _ctx)
            adopt_follower(host, hosted, { "live" => row.live }, runs: workspace.runs,
              turn: row.turn, run_public_id: row.run_public_id)
          end
      end
    end
  end
end
