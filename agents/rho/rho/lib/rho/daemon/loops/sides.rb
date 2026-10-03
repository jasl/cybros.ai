module Rho
  class Daemon
    class Loops
      # THE SIDE CONVERSATION, rho's
      # bookkeeping over the kernel's side fork. The kernel gives the
      # fork — a child at the live head from the parent's last SETTLED
      # turn, the inherited history behind its boundary item, the
      # parent's prefix bytes shared — and refuses a side of a side; it
      # keeps no rule about how many sides a parent has or how long an
      # idle one stands. Those are an application's, and here they are
      # rho's: ONE open side per parent (both verbs reuse it), a 24 h idle
      # TTL swept by the maintenance worker, and the sentence the model
      # reads — one inline USER-role entry at the TAIL of every side turn,
      # behind the inherited history as every positioned entry rides, so
      # the prefix the side shares with its parent stays the parent's. No
      # developer lead rides a side turn at all. The tool posture is the caller's
      # per-turn narrowing, as on any turn: `read` sends rho's read-only
      # subset (`rho side`, and every `rho say` on the side after it);
      # `none` (`rho btw`) means NO CALL RUNS, not "no tools declared" —
      # the parent's WHOLE set rides the turn, because the provider's
      # prefix cache needs the parent's tool block ahead of the messages
      # (a tool-less btw read 0 cached tokens against the parent's 5,632 on identical entries), the turn is tightened to
      # `ask`, and every park it raises is denied here with one sentence —
      # Claude Code's own shape: tools present, blocked by permission.
      module Sides
        SIDE_NOTE = "rho.side".freeze
        SIDE_TOOLS = %w[none read].freeze
        # THE ONE MODEL-FACING SENTENCE the auto-deny writes: the reason a
        # denied park carries (`error.detail`), read by the model's next
        # round. Beside `SIDE_LEADS`, the only bytes of rho's the model
        # reads on a side.
        SIDE_DENIAL = "Denied: no tool runs in this side conversation; answer from what is already in context.".freeze
        # The kernel's word for "hold every call for a decision".
        SIDE_APPROVAL = "ask".freeze

        # rho's read-only list; the kernel knows no such class. Narrowed to
        # what the turn's tier declares, in this order.
        READ_ONLY_SUBSET = %w[read grep ls find read_process memory_read].freeze
        # rho's number, not the kernel's: a side nobody spoke in for a day
        # is deleted through the kernel's door (tombstone and reap at once).
        SIDE_IDLE_TTL = 24 * 3600
        # ONE sentence per posture, model-facing (memory: model-facing names
        # are load-bearing): what the turns above are, and what may be done.
        SIDE_LEADS = {
          "none" => "You are in a side conversation: the turns above are the main conversation's history, " \
                    "inherited as reference only; answer the question below briefly from what is already in " \
                    "context, without tools.",
          "read" => "You are in a side conversation: the turns above are the main conversation's history, " \
                    "inherited as reference only; answer the question below briefly, reading files if you must, " \
                    "and change nothing.",
        }.freeze

        # `POST /side` `{parent_public_id?, text?, tools: none|read}`: the
        # parent is the row named — a conversation this daemon follows, or a
        # side it opened — else the newest live conversation in the store;
        # the open side is reused, else the kernel forks one and it is
        # followed and remembered with the parent's model, tier and runner
        # under the side note. With `text`, one `direct_reply` goes out on
        # the side — `queue`, the posture's subset, the tail — and the
        # answer waits for the loop the kernel mints, as `do` does, so a
        # reader joining next follows THIS turn and not the last one's
        # settle. 201 for a side just opened, 200 for one reused.
        def side(request, ctx)
          ctx.member_plane(request, body: true, require_workspace: false) do |client, workspace_public_id, _about, body|
            tools = body.fetch("tools", "none").to_s
            next Refusal.malformed("tools must be none or read") unless SIDE_TOOLS.include?(tools)

            parent_id, parent_row, side_row = resolve_side(body["parent_public_id"].to_s, client)
            next Refusal.not_followed(body["parent_public_id"].to_s, lane: :host, hint: "open the parent conversation first") if parent_id.nil?

            workspace_public_id = (parent_row || side_row).workspace
            workspace = client.workspace(workspace_public_id)
            opened = side_row.nil?
            if opened
              next Refusal.not_followed(parent_id, lane: :host, hint: "attach it first") if parent_row.nil?

              side_row = open_side(parent_id, parent_row, workspace,
                Extensions::MemberPlane.new(client: client, workspace_public_id: workspace_public_id))
            end
            host = side_row.host
            hosted = host.context(workspace)
            stamp_side(host, side_row, hosted, tools: tools)
            readopt_row(side_row, host, hosted, workspace, ctx) if @lineage.run(host.public_id).nil?
            answer = { side: { public_id: host.public_id }, parent: { public_id: parent_id }, reused: !opened,
                       tools: tools, lead: SIDE_LEADS.fetch(tools) }
            text = body["text"].to_s
            next [opened ? 201 : 200, answer] if text.strip.empty?

            ask_on_side(client, host, hosted, store.find(host.public_id), text, tools).then do |turn|
              next turn if turn in Refusal

              [opened ? 201 : 200, answer.merge(turn)]
            end
          end
        end

        # THE IDLE SWEEP, once per maintenance cycle: every side whose last
        # turn is older than the TTL — in the adopted workspace — is deleted
        # through the kernel's door, its follower ended, its row forgotten.
        # Answers the ids swept; a member plane that cannot be reached
        # sweeps nothing this cycle.
        def sweep_sides(now)
          answer = @context.member_plane(require_workspace: false) do |client|
            side_workspaces(client).flat_map do |workspace_id|
              workspace = client.workspace(workspace_id)
              owned_side_rows(workspace).filter_map do |row|
                discard_side(row, workspace) if idle_past?(row, now)
              end
            end
          end
          (answer in Refusal) ? [] : answer.compact
        rescue Rho::StateError => error
          @log.warn("side.sweep_failed", detail: error.message)
          []
        end

        # The input a `say` on a side row posts: the posture's tools and
        # the tail, in the mode the person chose; never a lead.
        # A side row takes a picture as its own tail: the
        # parent's prefix is untouched.
        def side_fields(host, row, text, mode:, model:, tier:, attachments: nil, schedule: {}, tool_names: nil)
          side_turn_fields(host, text, mode: mode, model: model, tier: tier, tools: row.notes.fetch(SIDE_NOTE).fetch("tools", "none"),
            foreign: row.foreign?, attachments: attachments, schedule: schedule, tool_names: tool_names)
        end

        def side_row?(row) = row.notes.key?(SIDE_NOTE)

        # THE AUTO-DENY: a park announced on a `none` side — the btw turn
        # called a tool under `ask` — is denied through the kernel's door,
        # each held key with the side sentence, on the loop the feed named;
        # a `read` side's park, and every plain host's, is a person's to
        # decide. A key the kernel already settled (`not_awaiting_approval`)
        # or a door that cannot be reached is logged, never raised: the
        # follower this runs on must outlive it.
        def follow_attention(run, attention, loops, source_loop_public_id, hosted:)
          return unless attention.reason == "approval_required" && loops
          return if source_loop_public_id.nil?

          row = follow_row(run, hosted)
          return unless row && side_row?(row) && row.notes.fetch(SIDE_NOTE)["tools"] == "none"

          attention.blocked_task_keys.each do |task_key|
            loops.agent_loop(source_loop_public_id).tasks_context(task_key).deny(reason: SIDE_DENIAL)
            @log.info("side.park_denied", side: run.public_id, loop: source_loop_public_id, task: task_key)
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            @log.warn("side.park_deny_failed", side: run.public_id, loop: source_loop_public_id, task: task_key,
              error_class: error.class.name, code: error.code, error: CybrosAgent::Redaction.call(error.message))
          end
        end

        # A turn on the side keeps it alive: the note's `last_turn_at` moves.
        def touch_side(host, row, hosted)
          stamp_side(host, row, hosted, last_turn_at: @clock.call.iso8601)
        end

        private

          # `[parent id, parent row, open side row]`: an empty name picks the
          # newest live conversation that is not a side; a side's own id
          # names it and its parent; a name the store lacks answers nils.
          def resolve_side(named, client)
            row = named.empty? ? newest_conversation : store.find(named)
            return [nil, nil, nil] if row.nil? || row.host_type != "conversation"
            workspace = client.workspace(row.workspace)
            row = hydrate_policy(row, row.host.context(workspace))
            return [row.notes.fetch(SIDE_NOTE).fetch("parent"), nil, row] if side_row?(row)

            [row.host_public_id, row, open_side_of(row.host_public_id, workspace)]
          end

          def newest_conversation
            store.rows.reverse.find { |row| row.host_type == "conversation" && !side_row?(row) }
          end

          def open_side_of(parent_id, workspace)
            row = owned_side_rows(workspace).find { |candidate| candidate.notes.fetch(SIDE_NOTE)["parent"] == parent_id }
            if row
              remember(row.host, workspace: row.workspace, live: row.live, runner: row.runner, answerer: row.answerer,
                model: row.model, compose: row.compose, notes: row.notes)
            end
            row
          end

          # Discover through Nexus's existing side collection. Losing or evicting
          # a follower row cannot hide an open side or disable its idle cleanup.
          def owned_side_rows(workspace)
            after = nil
            rows = []
            loop do
              page = workspace.conversations.list(side: true, after: after)
              page.items.each do |conversation|
                host = Rho::Host::Conversation.new(public_id: conversation.public_id)
                hosted = host.context(workspace)
                policy = policy_for(host, hosted).read
                next unless policy&.owner_public_id == @context.own_user_public_id && policy.notes.key?(SIDE_NOTE)

                document = hosted.fetch
                cached = store.find(host.public_id)
                rows << HostStore::Row.new(host_type: host.type, host_public_id: host.public_id,
                  workspace: workspace.public_id, live: cached ? cached.live : true,
                  remembered_at: cached&.remembered_at.to_s, turn: cached&.turn, loop: cached&.loop,
                  runner: document.runner&.executor_public_id,
                  answerer: (document.answering_user_public_id unless document.answering_user_public_id == @context.own_user_public_id),
                  model: policy.model, compose: policy.compose, notes: policy.notes)
              end
              after = page.next_after
              break if after.nil?
            end
            rows
          end

          def side_workspaces(client)
            ids = store.rows.map(&:workspace)
            [false, true].each do |dedicated|
              after = nil
              loop do
                page = client.workspaces.list(dedicated_to_current_agent: dedicated, after: after)
                ids.concat(page.items.map(&:public_id))
                after = page.next_after
                break if after.nil?
              end
            end
            ids.uniq
          end

          # THE KERNEL'S SIDE FORK, once: the kernel selects the answerer at
          # the fork point and copies the runner and billing; this row copies what rho
          # keeps beside them — the model, the tier and the runner it last
          # learned (a side never renders a lead: `say`'s side gate).
          # THE SIDE'S ENVIRONMENT: born with the
          # kernel's fork copy of the parent's record, so the parent's
          # tuple is memoized under the side at once and relayed when the
          # side's runner — the parent's — is elsewhere.
          def open_side(parent_id, parent_row, workspace, plane)
            forked = parent_row.host.context(workspace).fork(side: true, idempotency_key: SecureRandom.uuid)
            host = Rho::Host::Conversation.new(public_id: forked.conversation.public_id)
            answerer = forked.conversation.answering_user_public_id
            now = @clock.call.iso8601
            remember(host, workspace: parent_row.workspace, model: parent_row.model, compose: parent_row.compose,
              runner: parent_row.runner, answerer: (answerer unless answerer == @context.own_user_public_id),
              notes: { SIDE_NOTE => { "parent" => parent_id, "tools" => "none", "opened_at" => now, "last_turn_at" => now } })
            create_policy(host, host.context(workspace), model: parent_row.model, compose: parent_row.compose,
              notes: { SIDE_NOTE => { "parent" => parent_id, "tools" => "none", "opened_at" => now, "last_turn_at" => now } })
            inherit_environment(host, parent_id, parent_row, plane)
            @log.info("side.opened", side: host.public_id, parent: parent_id)
            store.find(host.public_id)
          end

          def inherit_environment(host, parent_id, parent_row, plane)
            binding = @environments.binding_for(parent_id, plane: plane)
            return if binding.nil?

            @environments.remember_copy(host.public_id, binding)
            return if parent_row.runner.nil? || @context.own_runner?(parent_row.runner)

            @environments.assert_remote(host.public_id, parent_row.runner, binding, plane: plane, wait: false)
          rescue StandardError => error
            @log.warn("environment.side_copy_failed", side: host.public_id, parent: parent_id, error_class: error.class.name)
          end

          def stamp_side(host, row, hosted, **facts)
            note = row.notes.fetch(SIDE_NOTE).merge(facts.transform_keys(&:to_s))
            save_policy(host, hosted, notes: row.notes.merge(SIDE_NOTE => note))
          end

          # The question on the side: the tier is the row's (the parent's,
          # copied), the tools are the posture's, the tail is the sentence;
          # a runner elsewhere has its names declared first, as `say` does.
          # The loop waited for is the one minted for THIS input: a reused
          # side's follower still holds the last question's settled loop,
          # and answering that one sent `rho btw` to print the last answer.
          def ask_on_side(client, host, hosted, row, text, tools)
            surface = turn_surface(client, row.runner)
            tier = tier_for(client, model: row.model, compose: row.compose, surface: surface)
            declare(client) if surface.remote?
            fields = side_turn_fields(host, text, mode: "queue", model: row.model, tier: tier, tools: tools, foreign: row.foreign?)
            run = @lineage.run(host.public_id)
            position = run&.event_position || CybrosAgent::KernelFeed::Position.start
            accepted = hosted.inputs.create(**fields, idempotency_key: SecureRandom.uuid)
            touch_side(host, row, hosted)
            outcome, value = await_materialization(hosted, accepted, position)
            return Refusal.input_blocked(host.public_id, value) if outcome == :blocked

            materialized_answer(outcome, value).merge(input: input_receipt(accepted, position))
          end

          # ONE SHAPE for every side turn. `none`: the tier's names as the
          # parent's own `say` sends them (nil = the whole declaration) and
          # the `ask` tightening; a foreign answerer's whole declaration
          # belongs to that profile, so rho's personal subset cannot ride.
          # `read`: rho's subset, the profile's word. An explicit subset
          # can narrow either posture further, including [] for an ingress
          # that must not carry the parent's executable declarations.
          def side_turn_fields(host, text, mode:, model:, tier:, tools:, foreign:, attachments: nil, schedule: {}, tool_names: nil)
            names = if tools == "none"
              tier.tool_names unless foreign
            else
              READ_ONLY_SUBSET & (tier.tool_names || names_of(tier.tools))
            end
            unless tool_names.nil?
              subset = Array.try_convert(tool_names)
              return Refusal.malformed("tool_names must be a list") if subset.nil?
              return Refusal.malformed("tool_names cannot expand a side conversation's tool posture") if names && (subset - names).any?

              names = subset
            end
            host.input_fields(text, mode: mode, model: model, tool_names: names,
              approval_mode: (SIDE_APPROVAL if tools == "none"), attachments: attachments, **schedule)
              .merge(inline: [side_tail(tools)])
          end

          def side_tail(tools) = { "role" => "user", "position" => "tail", "text" => SIDE_LEADS.fetch(tools) }

          def idle_past?(row, now)
            last = row.notes.fetch(SIDE_NOTE)["last_turn_at"]
            last.nil? || Time.iso8601(last) <= now - SIDE_IDLE_TTL
          rescue ArgumentError
            true
          end

          # The kernel's DELETE on a side is tombstone AND reap at once; a
          # side the kernel already lost is swept all the same.
          def discard_side(row, workspace)
            host = row.host
            begin
              host.context(workspace).delete
            rescue CybrosAgent::Api::NotFound
              nil
            end
            forget(host)
            @log.info("side.swept", side: host.public_id, parent: row.notes.fetch(SIDE_NOTE)["parent"])
            host.public_id
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            @log.warn("side.sweep_failed", side: row.host_public_id, error_class: error.class.name,
              error: CybrosAgent::Redaction.call(error.message))
            nil
          end
      end
    end
  end
end
