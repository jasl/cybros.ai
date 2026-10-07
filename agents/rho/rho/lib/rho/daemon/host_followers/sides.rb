module Rho
  class Daemon
    class HostFollowers
      # rho owns one reusable side per parent and its 24-hour idle cleanup.
      # The kernel owns the fork, reference boundary and shared history. Each
      # side turn adds its posture as a user tail, preserving that prefix.
      # Write uses the answerer's ordinary declaration and approvals; read
      # narrows the declaration to the read-only subset.
      module Sides
        SIDE_NOTE = "rho.side".freeze
        SIDE_TOOLS = %w[read write].freeze
        # rho's read-only list; the kernel knows no such class. Narrowed to
        # what the turn's selection declares, in this order.
        READ_ONLY_SUBSET = %w[read grep ls find read_process memory_read].freeze
        # rho's number, not the kernel's: a side nobody spoke in for a day
        # is deleted through the kernel's door (tombstone and reap at once).
        SIDE_IDLE_TTL = 24 * 3600
        # ONE sentence per posture, model-facing (memory: model-facing names
        # are load-bearing): what the turns above are, and what may be done.
        SIDE_LEADS = {
          "read" => "You are in a side conversation: the turns above are the main conversation's history, " \
                    "inherited as reference only; answer the question below briefly, reading files if you must, " \
                    "and change nothing.",
          "write" => "You are in a side conversation: the turns above are the main conversation's history, " \
                     "inherited as reference only; handle the request below using the available tools and ordinary approvals. " \
                     "File changes affect the same working environment as the main conversation; coordinate overlapping edits.",
        }.freeze

        # `POST /side` `{parent_public_id?, text?, tools: read|write, approval_mode?}`: the
        # parent is the row named — a conversation this daemon follows, or a
        # side it opened — else the newest live conversation in the store;
        # the open side is reused, else the kernel forks one and it is
        # followed and remembered with the parent's model and runner
        # under the side note. With `text`, one `direct_reply` goes out on
        # the side — `queue`, the posture's subset, the tail — and the
        # answer waits for the run the kernel mints, as `do` does, so a
        # reader joining next follows THIS turn and not the last one's
        # settle. 201 for a side just opened, 200 for one reused.
        def side(request, ctx)
          ctx.member_plane(request, body: true, require_workspace: false) do |client, workspace_public_id, _about, body|
            next Refusal.malformed("code_mode must be true, false or null") unless CodeMode.valid?(body["code_mode"])
            tools = body.fetch("tools", "write").to_s
            next Refusal.malformed("tools must be read or write") unless SIDE_TOOLS.include?(tools)
            next Refusal.malformed("approval_mode must be bypass, ask or rules") unless APPROVAL_MODES.include?(body["approval_mode"])

            parent_id, parent_row, side_row = resolve_side(body["parent_public_id"].to_s, client)
            next Refusal.not_followed(body["parent_public_id"].to_s, lane: :host, hint: "open the parent conversation first") if parent_id.nil?

            source = side_row || parent_row
            next Refusal.malformed("code_mode belongs to rho: the answerer is another agent") if source.foreign? && !own_named_answerer(source.answerer) && body.key?("code_mode")

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
            save_policy(host, hosted, code_mode: body["code_mode"]) if body.key?("code_mode")
            stamp_side(host, store.find(host.public_id), hosted, tools: tools)
            readopt_row(side_row, host, hosted, workspace, ctx) if @lineage.follower(host.public_id).nil?
            answer = { side: { public_id: host.public_id }, parent: { public_id: parent_id }, reused: !opened,
                       tools: tools, lead: SIDE_LEADS.fetch(tools) }
            text = body["text"].to_s
            next [opened ? 201 : 200, answer] if text.strip.empty?

            ask_on_side(client, host, hosted, store.find(host.public_id), text, tools, approval_mode: body["approval_mode"]).then do |turn|
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
        def side_fields(host, row, text, mode:, model:, selection:, attachments: nil, schedule: {}, tool_names: nil, approval_mode: nil)
          side_turn_fields(host, text, mode: mode, model: model, selection: selection, tools: row.notes.fetch(SIDE_NOTE).fetch("tools", "write"),
            foreign: row.foreign? && !own_named_answerer(row.answerer), attachments: attachments, schedule: schedule,
            tool_names: tool_names, approval_mode: approval_mode)
        end

        def side_row?(row) = row.notes.key?(SIDE_NOTE)

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
            store.rows.reverse.find do |row|
              row.host_type == "conversation" && !side_row?(row) && !row.notes.key?(Rho::MemoryReview::NAMESPACE)
            end
          end

          def open_side_of(parent_id, workspace)
            row = owned_side_rows(workspace).find { |candidate| candidate.notes.fetch(SIDE_NOTE)["parent"] == parent_id }
            if row
              remember(row.host, workspace: row.workspace, live: row.live, runner: row.runner, answerer: row.answerer,
                model: row.model, notes: row.notes)
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
                  remembered_at: cached&.remembered_at.to_s, turn: cached&.turn, run_public_id: cached&.run_public_id,
                  runner: document.default_runner&.executor_public_id,
                  answerer: (document.answering_user_public_id unless document.answering_user_public_id == @context.own_user_public_id),
                  model: policy.model, notes: policy.notes, code_mode: policy.code_mode)
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
          # keeps beside them — the model and the runner it last
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
            remember(host, workspace: parent_row.workspace, model: parent_row.model,
              runner: parent_row.runner, answerer: (answerer unless answerer == @context.own_user_public_id),
              notes: { SIDE_NOTE => { "parent" => parent_id, "tools" => "write", "opened_at" => now, "last_turn_at" => now } })
            create_policy(host, host.context(workspace), model: parent_row.model, code_mode: parent_row.code_mode,
              notes: { SIDE_NOTE => { "parent" => parent_id, "tools" => "write", "opened_at" => now, "last_turn_at" => now } })
            inherit_environment(host, parent_id, parent_row, plane)
            @log.info("side.opened", side: host.public_id, parent: parent_id)
            store.find(host.public_id)
          end

          def inherit_environment(host, parent_id, parent_row, plane)
            binding = @environments.binding_for(parent_id, plane: plane, runner: parent_row.runner)
            return if binding.nil?

            @environments.remember_copy(host.public_id, binding, runner: parent_row.runner)
            return if parent_row.runner.nil? || @context.own_runner?(parent_row.runner)

            @environments.assert_remote(host.public_id, parent_row.runner, binding, plane: plane, wait: false)
          rescue StandardError => error
            @log.warn("environment.side_copy_failed", side: host.public_id, parent: parent_id, error_class: error.class.name)
          end

          def stamp_side(host, row, hosted, **facts)
            note = row.notes.fetch(SIDE_NOTE).merge(facts.transform_keys(&:to_s))
            save_policy(host, hosted, notes: row.notes.merge(SIDE_NOTE => note))
          end

          # The question on the side selects tools for its inherited runner,
          # narrows them to the side's posture and adds the tail sentence;
          # a runner elsewhere has its names declared first, as `say` does.
          # The run waited for is the one minted for THIS input: a reused
          # side's follower still holds the last question's settled run,
          # so this input must not reuse that earlier execution.
          def ask_on_side(client, host, hosted, row, text, tools, approval_mode: nil)
            code_mode = CodeMode.enabled?(@config, row.code_mode)
            plane = Extensions::MemberPlane.new(client: client, workspace_public_id: row.workspace)
            record = @environments.read(host.public_id, plane: plane, runner: row.runner)
            surface = turn_surface(client, row.runner, binding: record.binding, code_mode: code_mode)
            named_answerer = own_named_answerer(row.answerer)
            selection = tool_selection(client, surface: surface, code_mode: code_mode, answerer: named_answerer)
            fields = side_turn_fields(host, text, mode: "queue", model: row.model, selection: selection, tools: tools,
              foreign: row.foreign? && !named_answerer, approval_mode: approval_mode)
            run = @lineage.follower(host.public_id)
            position = run&.event_position || CybrosAgent::KernelFeed::Position.start
            accepted = hosted.inputs.create(**fields, idempotency_key: SecureRandom.uuid)
            touch_side(host, row, hosted)
            outcome, value = await_materialization(hosted, accepted, position)
            return Refusal.input_blocked(host.public_id, value) if outcome == :blocked

            materialized_answer(outcome, value).merge(input: input_receipt(accepted, position))
          end

          # Write keeps the ordinary selected declaration. A foreign answerer's
          # declaration belongs to that profile, so rho does not substitute its
          # personal names. Explicit tool_names
          # can only narrow the posture, including [] for ingress restrictions.
          def side_turn_fields(host, text, mode:, model:, selection:, tools:, foreign:, attachments: nil, schedule: {}, tool_names: nil, approval_mode: nil)
            names = if tools == "read"
              READ_ONLY_SUBSET.flat_map do |served|
                selection.tools.filter_map do |entry|
                  name = entry.fetch("function").fetch("name")
                  name if (entry.dig("route", "tool_name") || name) == served
                end
              end
            else
              selection.tool_names unless foreign
            end
            unless tool_names.nil?
              subset = Array.try_convert(tool_names)
              return Refusal.malformed("tool_names must be a list") if subset.nil?
              return Refusal.malformed("tool_names cannot expand a side conversation's tool posture") if names && (subset - names).any?

              names = subset
            end
            host.input_fields(text, mode: mode, model: model, tool_names: names,
              approval_mode: approval_mode, attachments: attachments, **schedule)
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
