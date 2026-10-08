module Rho
  module Extensions
    module Ops
      module RunRoutes
        class << self
          # THE REPLAY'S MAINLINE: a conversation's
          # turns in position order, the kernel's window (`TURN_PAGE` rows a
          # read) paged from `after_position` to the END under a cap of
          # `TURNS_PAGE_CAP` windows — or to `limit` rows when one is named
          # — and answered per turn as the replay reads it: the id, the
          # position, the kind, the role, the status, the origin, whether
          # it is inherited history (not a new answer on this conversation), and the
          # active variant's content, backing run and source (absent on a
          # reply that minted none) and, on a reply turn, `prompt_text` —
          # the person's words that OPENED it, off the variant's seed, absent on a message turn
          # and on a wordless seed. `pagination` carries the last position
          # read (the next read's window) and whether more stands past it.
          # The page's latest/older reads are single reverse windows, still
          # rendered in position order, with their own `has_older` cursor.
          def turns(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            after = query["after_position"]
            before = query["before_position"]
            latest = query["latest"] == "1"
            limit = query["limit"]
            after = Integer(after, exception: false) if after
            before = Integer(before, exception: false) if before
            limit = Integer(limit, exception: false) if limit
            return Rho::Daemon::Refusal.malformed("after_position must be an integer") if query["after_position"] && after.nil?
            return Rho::Daemon::Refusal.malformed("before_position must be an integer") if query["before_position"] && before.nil?
            return Rho::Daemon::Refusal.malformed("limit must be a positive integer") if query["limit"] && !limit&.positive?
            if [!after.nil?, !before.nil?, latest].count(true) > 1
              return Rho::Daemon::Refusal.malformed("give after_position, before_position or latest, never more than one")
            end

            ctx.member_plane(request) do |client, workspace_public_id|
              turns = client.workspace(workspace_public_id).conversation(public_id).turns
              next turn_window(turns, before: before, latest: latest, limit: limit) if before || latest

              rows, has_more = turn_pages(turns, after: after, limit: limit)
              [200, { turns: rows.map { |turn| turn_entry(turn) },
                      pagination: { after_position: rows.last&.position, has_more: has_more } }]
            end
          end

          # A full page may have more before it. As on the forward route,
          # one final empty window is enough to establish the end.
          def turn_window(turns, before:, latest:, limit:)
            size = limit || Ops::TURN_PAGE
            page = latest ? Ops.newest_turns(turns, limit: size) : turns.list(before_position: before, limit: size)
            [200, { turns: page.items.map { |turn| turn_entry(turn) },
                    pagination: { before_position: page.before_position, after_position: page.after_position,
                                  has_older: page.items.length == size } }]
          end

          # Windows of `TURN_PAGE` (or what `limit` leaves), each after the
          # last row read, until a short window (the end), the limit, or
          # the cap. Answers the rows and whether more stands past them.
          def turn_pages(turns, after:, limit:)
            rows = []
            TURNS_PAGE_CAP.times do
              size = limit ? [limit - rows.length, Ops::TURN_PAGE].min : Ops::TURN_PAGE
              return [rows, true] unless size.positive?

              page = turns.list(**({ after_position: after } unless after.nil?), limit: size).items
              rows.concat(page)
              return [rows, false] if page.length < size

              after = page.last.position
            end
            [rows, true]
          end

          def turn_entry(turn)
            variant = turn.active_variant
            { public_id: turn.public_id, position: turn.position, kind: turn.kind, role: turn.role,
              input_public_id: turn.input_public_id, callback_sources: turn.callback_sources.map(&:to_h),
              status: turn.status, origin: turn.origin, inherited: turn.inherited, reference: turn.reference,
              sender_conversation_public_id: turn.sender_conversation_public_id,
              sender_run_public_id: turn.sender_run_public_id, sender_task_key: turn.sender_task_key,
              created_at: turn.created_at, speaker: turn.speaker&.to_h, answering_user_public_id: turn.answering_user_public_id,
              active_variant: variant && { public_id: variant.public_id, model: variant.model&.to_h,
                                           content: variant.content, content_preview: variant.content_preview,
                                           prompt_text: variant.prompt_text, attachments: variant.attachments&.map(&:to_h),
                                           run_public_id: variant.run_public_id,
                                           details_pruned_at: variant.details_pruned_at,
                                           source: variant.source }.compact.merge(memory_context: variant.memory_context) }.compact
          end

          # A known conversation can be read without a follower, including after
          # archive forgets its local routing hint. With no explicit host type,
          # resolve a followed host or backing run through the existing rule.
          def inputs(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            host_type = query["host_type"]
            unless host_type.nil? || host_type == CONVERSATION_ARM
              return Rho::Daemon::Refusal.malformed("host_type must be #{CONVERSATION_ARM}, or absent for a run")
            end

            ctx.member_plane(request) do |client, workspace_public_id|
              host = input_host(ctx, client, workspace_public_id, public_id, host_type)
              queue = host.context(client.workspace(workspace_public_id)).inputs.list
              [200, { host_public_id: host.public_id, inputs: queue.items.map { |row| input_row(row) },
                      input_queue: { limit: queue.input_queue.limit, held: queue.input_queue.held } }]
            end
          end

          # GIVE UP A ROW: the SDK's `inputs.delete` on the host the id
          # names. A kernel-origin row's 409 (`kernel_input_immutable`)
          # relays as itself.
          def delete_input(request, ctx)
            input_command(request, ctx) do |host, inputs, input_public_id|
              inputs.delete(input_public_id)
              [200, { deleted: { public_id: input_public_id, host_public_id: host.public_id } }]
            end
          end

          # REWRITE A ROW — the unblock path: the text alone, no lock
          # fence, because the person at this terminal is the row's one
          # writer; the kernel re-checks the head when it drains.
          # The kernel's two "not before" spellings.
          SCHEDULE_FIELDS = %w[deliver_at deliver_in].freeze

          # A time beside the words: `deliver_at`/`deliver_in` pass through as typed — the
          # kernel is the one parser — and the words are optional beside
          # one; the kernel's refusal relays as itself.
          def update_input(request, ctx)
            input_command(request, ctx) do |_host, inputs, input_public_id, body|
              text = body["text"].to_s
              schedule = SCHEDULE_FIELDS.to_h { |key| [key.to_sym, body[key]] }.compact
              next Rho::Daemon::Refusal.malformed("deliver_at and deliver_in are strings") unless
                schedule.values.all?(String)
              mode = body["delivery_mode"]
              next Rho::Daemon::Refusal.malformed("delivery_mode must be steer_now") if mode && mode != "steer_now"
              next Rho::Daemon::Refusal.malformed("text is required, or deliver_at / deliver_in / delivery_mode") if
                text.strip.empty? && schedule.empty? && !mode

              fields = text.strip.empty? ? schedule : schedule.merge(text: text)
              fields[:delivery_mode] = mode if mode
              [200, { input: input_row(inputs.update(input_public_id, **fields)) }]
            end
          end

          # WHO MAY SEE A CONVERSATION of this daemon's adopted workspace:
          # the member plane — NOT `host_command`, a person may
          # re-cut a conversation this daemon does not follow — the SDK's
          # fetch for the carrier as it stands, then, when the body names a
          # change, the whole set re-cut and PUT back. A `none` row is the
          # kernel's 404 relayed as itself; a `read` caller its 403.
          # THE PREVIEW ROUTE: `POST …/context_estimate`
          # with `render: true` — the bytes a send of these words would
          # seal, compiled under the addressee `to` names (the kernel's
          # own word, `@handle` or a public id, passed verbatim: the kernel
          # is the one resolver) with rho as the author; the turn's
          # `variables` and a trial `template` ride the same body and are
          # judged by the kernel's grammar (its 422 relays as itself). The
          # model is the flag's, else the one `say` would send the next turn
          # on (`HostFollowers#conversation_model`): a preview names an existing
          # conversation, whose next send is `say`, never `do`, and a preview
          # compiled on another model would count another budget. Nothing is
          # written: no row, no invocation.
          def prompt_preview(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              public_id = body["public_id"].to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

              workspace = client.workspace(workspace_public_id)
              model = body["model"].to_s
              model = ctx.conversation_model(public_id, workspace).to_s if model.empty?
              next Rho::Daemon::Refusal.malformed("model is required, as provider/reference") if model.empty?

              objects = %w[variables template].to_h { |key| [key, body[key]] }.compact
                .transform_values { |value| Hash.try_convert(value) }
              if objects.value?(nil)
                next Rho::Daemon::Refusal.malformed("variables and template must be objects")
              end

              estimate = workspace.conversation(public_id).estimate_input(
                model: model, render: true,
                **({ prompt: body["prompt"].to_s } unless body["prompt"].to_s.empty?),
                **({ to: body["to"].to_s } unless body["to"].to_s.empty?),
                **objects.transform_keys(&:to_sym)
              )
              [200, { preview: preview_document(estimate) }]
            end
          end

          # The profile's own slots (`rho prompt show`): the listing, or
          # one slot whole. The kernel's `prompt_slot_unavailable` relays.
          def prompt_documents(request, ctx)
            slot = ControlServer.query(request)["slot"].to_s
            ctx.member_plane do |client, _workspace_public_id|
              documents = client.profile.prompt_documents
              if slot.empty?
                [200, { prompt_documents: documents.list.map { |row| row.to_h.compact } }]
              else
                [200, { prompt_document: documents.read(slot).to_h }]
              end
            end
          end

          def access(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
              public_id = body["public_id"].to_s
              next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

              raw_change = body["change"]
              change = Hash.try_convert(raw_change)
              unless raw_change.nil? || (change && ACCESS_OPS.include?(change["op"]))
                next Rho::Daemon::Refusal.malformed("change.op must be add, rm or default")
              end

              chat = client.workspace(workspace_public_id).conversation(public_id)
              current = chat.fetch.access
              access = change.nil? ? current : chat.set_access(**replaced_access(current, change)).access
              [200, { conversation: { public_id: public_id }, access: access_row(access) }]
            end
          end

          # REWIND: the body judged, then `Ops.rewind` — the
          # fork-then-restore composition, answered whole. A failed restore
          # is a 200 (the child exists; its `restoration` says `failed`); a local
          # refusal is the member plane's own.
          def rewind(request, ctx)
            body = ControlServer.json_body(request)
            public_id = body["public_id"].to_s
            turn = body["turn"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("turn is required") if turn.empty?

            title = body["title"].to_s
            facts = Ops.rewind(ctx, public_id, turn, keep_checkpoints: body["keep_checkpoints"] == true,
              title: title.empty? ? nil : title, **body.slice("idempotency_key", "workspace_public_id").transform_keys(&:to_sym))
            return facts if facts in Rho::Daemon::Refusal

            [200, { rewind: { conversation: facts.conversation, forked_from: facts.forked_from,
                              position: facts.position, restoration: facts.restoration } }]
          end

          # REGENERATE: restore-first, then the door — `Ops.
          # regenerate` composes it and answers the turn, the new candidate
          # and the restoration outcome.
          def regenerate(request, ctx)
            body = ControlServer.json_body(request)
            public_id = body["public_id"].to_s
            turn = body["turn"].to_s
            idempotency_key = body["idempotency_key"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("turn is required") if turn.empty?
            return Rho::Daemon::Refusal.malformed("idempotency_key is required") if idempotency_key.empty?

            model = body["model"].to_s
            facts = Ops.regenerate(ctx, public_id, turn, idempotency_key: idempotency_key, keep_checkpoints: body["keep_checkpoints"] == true,
              model: model.empty? ? nil : model, **body.slice("workspace_public_id").transform_keys(&:to_sym))
            return facts if facts in Rho::Daemon::Refusal

            [200, { regenerate: { turn: facts.turn, variant: facts.variant, restoration: facts.restoration, replayed: facts.replayed } }]
          end

          # THE DECK: a turn's live candidates, the active
          # one flagged, through the SDK's `turns.variants` — the read a
          # person needs before naming a candidate to `rho variant`.
          def variants(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            turn = query["turn"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("turn is required") if turn.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              deck = client.workspace(workspace_public_id).conversation(public_id).turns.variants(turn)
              [200, { variants: deck.items.map(&:to_h), turn: { public_id: turn, inherited: deck.turn_inherited } }]
            end
          end

          # ONE CANDIDATE'S VIEW STATE: the SDK's
          # `set_variant_view_state` — `concealed` true hides a sample, false
          # restores it; the kernel's own words come back through the route
          # table's exception map (`variant_active`, `slot_occupied`).
          def variant(request, ctx)
            body = ControlServer.json_body(request)
            public_id = body["public_id"].to_s
            turn = body["turn"].to_s
            variant = body["variant"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("turn is required") if turn.empty?
            return Rho::Daemon::Refusal.malformed("variant is required") if variant.empty?
            return Rho::Daemon::Refusal.malformed("concealed must be true or false") unless [true, false].include?(body["concealed"])

            ctx.member_plane(host_public_id: public_id, **body.slice("workspace_public_id").transform_keys(&:to_sym)) do |client, workspace_public_id|
              written = client.workspace(workspace_public_id).conversation(public_id).turns
                .set_variant_view_state(turn, variant, concealed: body["concealed"])
              [200, { variant: written.to_h }]
            end
          end

          def activate_variant(request, ctx)
            body = ControlServer.json_body(request)
            public_id = body["public_id"].to_s
            turn = body["turn"].to_s
            variant = body["variant"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("turn is required") if turn.empty?
            return Rho::Daemon::Refusal.malformed("variant is required") if variant.empty?

            ctx.member_plane(host_public_id: public_id, **body.slice("workspace_public_id").transform_keys(&:to_sym)) do |client, workspace_public_id|
              written = client.workspace(workspace_public_id).conversation(public_id).turns.activate(turn, variant)
              [200, { variant: written.to_h }]
            end
          end

          private

            ACCESS_OPS = %w[add rm default].freeze

            # The whole set after one re-cut: `add` names or re-levels a
            # principal at the end of the list, `rm` drops one, `default`
            # changes the default and keeps the entries. The principal is
            # `@handle` or a public id: a kept row is matched
            # by either, the added row is sent as the kernel resolves it —
            # `handle` for an `@` word, `user_public_id` otherwise.
            def replaced_access(current, change)
              return { default: change["level"].to_s, entries: kept_entries(current.entries) } if change["op"] == "default"

              principal = change["principal"].to_s
              kept = current.entries.reject { |entry| entry.user_public_id == principal || "@#{entry.handle}" == principal }
              entries = kept_entries(kept)
              entries << principal_entry(principal).merge(level: change["level"].to_s) if change["op"] == "add"
              { default: current.default, entries: entries }
            end

            def kept_entries(entries) = entries.map { |entry| { user_public_id: entry.user_public_id, level: entry.level } }

            def principal_entry(principal)
              principal.start_with?("@") ? { handle: principal.delete_prefix("@") } : { user_public_id: principal }
            end

            # One document a terminal prints: the count and history as the
            # estimate answers them, then the preview half — the entries
            # verbatim, the storage line, one row per block, memory, the
            # slot versions — spelled as the kernel spells them.
            def preview_document(estimate)
              rendered = estimate.rendered
              {
                mechanism: rendered.mechanism,
                input_tokens: estimate.input_tokens,
                tokenizer_exact: estimate.tokenizer_exact,
                catalog_input_token_limit: estimate.catalog_input_token_limit,
                advisory_input_token_limit: estimate.advisory_input_token_limit,
                message_count: estimate.message_count,
                history: estimate.history.to_h,
                entries: rendered.entries,
                storage: rendered.storage.to_h,
                blocks: rendered.blocks.map(&:to_h),
                memory: rendered.memory.to_h,
                slots: rendered.slots,
              }
            end

            def access_row(access)
              { default: access.default, entries: access.entries.map(&:to_h) }
            end

            # The member plane, an explicit conversation or the host a followed id names, that host's
            # inputs door and the row the body names — the shape the two
            # queue writes share.
            def input_command(request, ctx)
              ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
                public_id = body["public_id"].to_s
                next Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

                input_public_id = body["input_public_id"].to_s
                next Rho::Daemon::Refusal.malformed("input_public_id is required") if input_public_id.empty?

                host_type = body["host_type"]
                unless host_type.nil? || host_type == CONVERSATION_ARM
                  next Rho::Daemon::Refusal.malformed("host_type must be #{CONVERSATION_ARM}, or absent for a run")
                end

                host = input_host(ctx, client, workspace_public_id, public_id, host_type)
                yield(host, host.context(client.workspace(workspace_public_id)).inputs, input_public_id, body)
              end
            end

            def input_host(ctx, client, workspace_public_id, public_id, host_type)
              if host_type
                Rho::Host::Conversation.new(public_id: public_id)
              else
                ctx.host_of(public_id, ctx.runs_for(client, workspace_public_id))
              end
            end

            # What a person needs to pick a row: its place, its state and
            # why it is parked, its kind, and the words (absent on a raw
            # entry list); `origin` is the row's source kind — `person`,
            # `agent`, or the kernel's `task_result`/`child`, which are
            # nobody's to change.
            def input_row(row)
              { public_id: row.public_id, queue_position: row.queue_position, state: row.state, kind: row.kind,
                delivery_mode: row.delivery_mode, text: row.text, blocked_reason: row.blocked_reason,
                tool_names: row.tool_names,
                callback_result: row.callback_result&.to_h,
                origin: row.origin, attachments: row.attachments&.map(&:to_h), deliver_at: row.deliver_at }.compact
            end
        end
      end
    end
  end
end
