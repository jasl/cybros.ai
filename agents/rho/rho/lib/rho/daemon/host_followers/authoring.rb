require "digest"

module Rho
  class Daemon
    class HostFollowers
      # Conversation creation and turn input construction share the host's policy.
      module Authoring
        private

          # `:turn_author`, in registration order, fail-CLOSED: the open is
          # refused rather than authored without what an extension meant to
          # add. A hook answers the Draft the next one sees, or a Refusal.
          def author_hooks(draft, ctx)
            @loaded.daemon_hooks.select { |hook| hook.event == :turn_author }.reduce(draft) do |current, hook|
              answer = hook.call(current, ctx)
              case answer
              in Refusal then return answer
              in Draft then answer
              end
            rescue StandardError => error
              @log.warn("turn_author_hook_failed", extension: hook.extension,
                error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
              return Refusal.extension_failed(hook.extension, error)
            end
          end

          # Observed conversation text is a plain user message. It enters the
          # same durable queue without rendering a reply or selecting a model.
          def say_message(host, hosted, row, body, workspace, client, ctx, text, mode)
            return Refusal.malformed("message is a queued conversation input") unless host.outlives_turn? && mode == "queue"
            reply_only_fields = %w[code_mode subagent model approval_mode tool_names to instructions deliver_at deliver_in inline expected_steering_run_public_id]
            return Refusal.malformed("message does not accept #{reply_only_fields.join(", ")}") if reply_only_fields.any? { |key| body.key?(key) }

            staged = input_attachments(client, body, ctx)
            return staged if staged in Refusal

            readopt_row(row, host, hosted, workspace, ctx) if @lineage.follower(host.public_id).nil?
            position = @lineage.follower(host.public_id)&.event_position || CybrosAgent::KernelFeed::Position.start
            fields = { kind: "message", role: "user", text: text, delivery_mode: "queue", visible_in_context: true }
            fields[:attachments] = staged.ids if staged.any?
            fields[:speaker_public_id] = input_speaker(client, ctx, body)
            accepted = admit_bot_input(client, hosted.fetch, hosted) do
              hosted.inputs.create(**fields, idempotency_key: body["idempotency_key"] || SecureRandom.uuid)
            end
            return accepted if accepted in Refusal
            [200, { input: input_receipt(accepted, position), default_runner: runner_answer(row) }]
          end

          # In this order: the row, so `say` can key on it from the first
          # moment and retain the binding the kernel answered;
          # the follower, so no `turn_status` is missed; then the input; then the
          # wait for the run the kernel mints, which is when the
          # `:turn_follow` hook can be fired and its gate installed. The
          # answer's `runner:` is the create response's binding — the
          # three-state slot a terminal prints — nil for none bound; this
          # machine's own runner carries its id alone, because kernel presence
          # is for a FOREIGN executor and rho's own planes print local truth
          # (a sweep-only rho reads `offline` while working, and "rho handoff moves them" would be a wrong sentence about itself).
          # For this application's answerers, tool selection has declared the
          # profile and assembled its names. Creation commits rho's policy before any follower or
          # input starts. With a root set: create → policy → environment
          # record on the new conversation's Store → the call_tool when
          # the runner is elsewhere (its row lands in the runner's inbox
          # ahead of the turn's rows: the inbox is ordered by id) → the
          # follower → the first input.
          def open_conversation(client, workspace_public_id, draft, selection, ctx, runner:, answerer: nil,
                                staged: Staged.none, root_set: nil)
            workspace = client.workspace(workspace_public_id)
            model = draft.body.fetch("model")
            # A named answerer other than rho is FOREIGN: the create names it,
            # the row remembers it, and the first turn carries the bare words.
            foreign = answerer && answerer.public_id != ctx.own_user_public_id
            policy = initial_policy(model: model, notes: draft.notes,
              **draft.body.slice("code_mode", "subagent").transform_keys(&:to_sym),
              model_selection: draft.body["model_selection"], title_pending: !foreign && draft.body["title"].to_s.empty?)
            fields = opening_input(client, ctx, draft, selection, answerer, bare: foreign)
            created = workspace.conversations.create(
              idempotency_key: draft.body["idempotency_key"] || SecureRandom.uuid,
              metadata: creation_metadata(policy, fields, root_set),
              **({ title: draft.body["title"] } if draft.body.key?("title")),
              memory_context: input_memory_context(client, ctx, draft.body),
              default_runner_executor_public_id: runner,
              **({ answering_user_public_id: answerer.public_id } if answerer),
              **({ access: access_at_birth(workspace, ctx, draft.body["access_default"]) } if draft.body["access_default"])
            )
            host = Rho::Host::Conversation.new(public_id: created.public_id)
            bound = created.conversation.default_runner&.executor_public_id
            draft = anchor_draft(draft, host.public_id)
            # A foreign row's open sends no lead (`reply_fields(bare:)`); rho's
            # own turns on it (`say --to @rho`) render one each, as every
            # plain turn does.
            remember(host, workspace: workspace_public_id,
              runner: bound, answerer: (answerer.public_id if foreign))
            row = create_policy(host, host.context(workspace), **policy.merge(notes: draft.notes))
            environment = bind_at_birth(host, root_set, bound, client, workspace_public_id)
            return environment if environment in Refusal

            hosted = host.context(workspace)
            run = adopt_follower(host, hosted, draft.body, runs: workspace.runs)
            position = run&.event_position || CybrosAgent::KernelFeed::Position.start
            # Creation and input receipts have separate kernel scopes, so the
            # caller's key safely covers both writes after a lost response.
            # The prepared input changes only by filling the new anchor.
            fields[:executor_contexts] = draft.body["executor_contexts"] if fields.key?(:executor_contexts)
            fields[:steps] = draft.steps if fields.key?(:steps)
            accepted = hosted.inputs.create(**fields,
              idempotency_key: draft.body["idempotency_key"] || SecureRandom.uuid)
            title_after_input(host, hosted, accepted, workspace, text: draft.body.fetch("prompt"), model: model)

            outcome, value = await_materialization(hosted, accepted, position)
            return Refusal.input_blocked(host.public_id, value) if outcome == :blocked

            run_public_id = (value.run_public_id if outcome == :materialized)
            conversation = { public_id: host.public_id }
            # `adaptations:` is
            # the model's row and its source, with the BOOT row beside it
            # when the two differ (the spellings are the boot's).
            answer = { conversation: conversation, input: input_receipt(accepted, position),
                       adaptations: @adaptations.facts(draft.body.fetch("model")) }
            answer[:environment] = environment if environment
            # The access line rides the answer only when the verb asked for a
            # default: the kernel's own `full` is not news; the answerer's
            # line only when one was named; the pictures only when staged.
            answer[:access] = created.conversation.access.default if draft.body["access_default"]
            answer[:answered_by] = { public_id: answerer.public_id, handle: answerer.handle } if answerer
            answer[:attachments] = staged.descriptors if staged.descriptors.any?
            binding = created.conversation.default_runner&.to_h
            binding = binding.slice(:executor_public_id) if binding && @context.own_runner?(bound)
            unless outcome == :materialized
              return [201, answer.merge(pending: true, follower: run&.snapshot&.to_h).compact.merge(default_runner: binding)]
            end

            if run_public_id
              remember(host, workspace: workspace_public_id, turn: value.turn, run_public_id: run_public_id)
              install_gate(run, follow_gate(run_public_id, row.notes, ctx)) if run && run.gate.nil?
            end
            # `until:` is the one named leak an extension puts on the `do`
            # verb's answer: its notes read
            # here, and deleted with the extension. Compacted: the store
            # keeps the policy's nils (an own runner, an unknown directory);
            # the answer names only what is.
            [201, answer.merge(materialized_answer(outcome, value)).merge(
              follower: run.snapshot.to_h, until: row.notes["rho.until"]&.except("seed")&.compact).compact.merge(default_runner: binding)]
          end

          def opening_input(client, ctx, draft, selection, answerer, bare:)
            fields = reply_fields(Rho::Host::Conversation, draft, selection, bare: bare)
            fields[:executor_contexts] = draft.body["executor_contexts"] unless draft.body["executor_contexts"].to_h.empty?
            fields.merge!(draft.body.slice("agent_configuration", "model_selection", "fallback_models").transform_keys(&:to_sym))
            fields[:speaker_public_id] = input_speaker(client, ctx, draft.body)
            fields[:tool_names] = selection.tool_names if own_named_answerer(answerer&.public_id)
            fields[:steps] = draft.steps unless draft.steps.nil?
            fields
          end

          # Nexus's create receipt binds all later writes to this intent, even
          # when creation stops before the first input reaches its own receipt.
          # Steps use their wire values; only the generated anchor is absent.
          def creation_metadata(policy, input, root_set)
            input = input.merge(steps: input.fetch(:steps).map(&:to_h)) if input&.key?(:steps)
            intent = { policy: policy, input: input, environment: root_set&.to_h }
            { "rho.creation_digest" => Digest::SHA256.hexdigest(JSON.generate(CybrosAgent::SizeBounds.canonical(intent))) }
          end

          def anchor_draft(draft, public_id)
            contexts = draft.body.fetch("executor_contexts", {}).transform_values do |context|
              value = context.fetch(Rho::Runner::Environment::CONTEXT_KEY)
              context.merge(Rho::Runner::Environment::CONTEXT_KEY => value.merge("anchor" => value["anchor"] || public_id))
            end
            notes = draft.notes
            if (note = notes["rho.until"])
              notes = notes.merge("rho.until" => note.merge("seed" => note.fetch("seed").merge("executor_contexts" => contexts)))
            end
            steps = draft.steps&.map do |step|
              if step in CybrosAgent::Steps::Tool
                step.with(executor_context: contexts[step.route&.fetch("runner_executor_public_id", nil)])
              else
                step
              end
            end
            draft.with(body: draft.body.merge("executor_contexts" => contexts), notes: notes, steps: steps)
          end

          # THE FIELDS ONLY A TURN CARRIES (the promptless open refuses each
          # by name rather than dropping it): the lead's instructions, the
          # pictures, the tightening, an extension's check.
          TURN_ONLY_FIELDS = %w[instructions attachments upload_public_ids approval_mode until].freeze

          # THE PROMPTLESS OPEN (a session IS a conversation, opened with no turn): the create-door fields alone
          # — the runner, the answerer, the access default — then the row
          # remembered and the feed followed, no input, no run, no model
          # check, no selection. The row keeps the model the flag named (the first
          # `say` rides it, else the settings' default); the first `say`
          # renders the lead, as every one does.
          # `working_directory` is descriptive text on a turn's lead and
          # constrains nothing; with no turn here it shapes nothing, and the
          # first `say` renders the environment from the root of that moment.
          # Answers 201: the conversation, the runner slot, the run.
          def open_promptless(client, workspace_public_id, body, ctx)
            turn_only = TURN_ONLY_FIELDS.select { |key| body.key?(key) }
            unless turn_only.empty?
              return Refusal.malformed("#{turn_only.join(", ")} ride#{"s" if turn_only.one?} the first turn: give a prompt")
            end
            unless ACCESS_DEFAULTS.include?(body["access_default"])
              return Refusal.malformed("access_default must be full, read or none")
            end

            answerer = body.key?("agent") ? resolve_answerer(client, workspace_public_id, body["agent"]) : nil
            return answerer if answerer in Refusal
            if (refusal = bot_open_refusal(client, answerer))
              return refusal
            end
            named_answerer = own_named_answerer(answerer&.public_id)
            foreign = answerer && answerer.public_id != ctx.own_user_public_id

            # THE ROOT SET (`session/new {cwd}` opens with no turn):
            # validated before the create, recorded after it.
            runner = opening_runner(body, ctx, foreign: foreign, named_answerer: named_answerer)
            root_set = root_set_of(body, runner)
            return root_set if root_set in Refusal

            workspace = client.workspace(workspace_public_id)
            return Refusal.malformed("conversation modes belong to rho: the answerer is another agent") if foreign && !named_answerer && (body.keys & %w[code_mode subagent]).any?
            # The row remembers the bot's model, so the first `say` rides it.
            effective_model = body["model"].to_s.strip
            intent = if !effective_model.empty? && (!foreign || named_answerer)
              { "source" => "explicit", "model" => effective_model, "constraint" => "route", "alternatives" => [] }
            end
            policy = initial_policy(model: (effective_model unless effective_model.empty?), notes: {},
              **body.slice("code_mode", "subagent").transform_keys(&:to_sym), model_selection: intent,
              title_pending: !foreign && body["title"].to_s.empty?)

            created = workspace.conversations.create(
              idempotency_key: body["idempotency_key"] || SecureRandom.uuid,
              metadata: creation_metadata(policy, nil, root_set),
              **({ title: body["title"] } if body.key?("title")),
              memory_context: input_memory_context(client, ctx, body),
              default_runner_executor_public_id: runner,
              **({ answering_user_public_id: answerer.public_id } if answerer),
              **({ access: access_at_birth(workspace, ctx, body["access_default"]) } if body["access_default"])
            )
            host = Rho::Host::Conversation.new(public_id: created.public_id)
            bound = created.conversation.default_runner&.executor_public_id
            remember(host, workspace: workspace_public_id,
              runner: bound, answerer: (answerer.public_id if foreign))
            create_policy(host, host.context(workspace), **policy)
            environment = bind_at_birth(host, root_set, bound, client, workspace_public_id)
            return environment if environment in Refusal

            run = adopt_follower(host, host.context(workspace), body, runs: workspace.runs)

            answer = { conversation: { public_id: host.public_id } }
            answer[:environment] = environment if environment
            answer[:access] = created.conversation.access.default if body["access_default"]
            answer[:answered_by] = { public_id: answerer.public_id, handle: answerer.handle } if answerer
            binding = created.conversation.default_runner&.to_h
            binding = binding.slice(:executor_public_id) if binding && @context.own_runner?(bound)
            [201, answer.merge(follower: run&.snapshot&.to_h).compact.merge(default_runner: binding)]
          end

          # Validate a named root before authoring. Remote paths are absolute;
          # their filesystem availability is checked by the selected Runner.
          def root_set_of(body, runner)
            named = body["environment"]
            return nil if named.nil?

            named = Hash.try_convert(named)
            return Refusal.malformed("environment must be an object with a root") if named.nil?

            root = named["root"]
            directories = named.fetch("directories", []) || []
            refusal = @environments.validate(root, directories, local: runner.nil? || @context.own_runner?(runner))
            return refusal if refusal

            local = runner.nil? || @context.own_runner?(runner)
            Rho::Runner::Environment::Binding.new(root: local ? File.expand_path(root) : root,
              directories: local ? directories.map { |path| File.expand_path(path) } : directories, anchor: nil)
          end

          # Save future authoring defaults under the new conversation anchor.
          def bind_at_birth(host, root_set, bound, client, workspace_public_id)
            return nil if root_set.nil?

            plane = Extensions::MemberPlane.new(client: client, workspace_public_id: workspace_public_id)
            written = @environments.bind(host.public_id, root: root_set.root, directories: root_set.directories,
              plane: plane, runner: bound, initialize_only: true)
            return written if written in Refusal

            { root: written.root, directories: written.directories, source: written.source }
          end

          # `@handle` or a public id over the principals listing (the address is resolved at the door; a bare handle is taken too, as the SDK's access entries take it); an empty word is malformed,
          # an unmatched one is `principal_unknown` naming what is known.
          # Eligibility is the KERNEL's (`answerer_not_eligible` relayed as
          # is): rho resolves a name, never a standing.
          def resolve_answerer(client, workspace_public_id, address)
            address = address.to_s.strip
            return Refusal.malformed("agent must name a principal, as @handle or a public id") if address.empty?

            principals = client.workspace(workspace_public_id).principals
            handle = address.delete_prefix("@")
            principals.find { |principal| principal.public_id == address || principal.handle == handle } ||
              Refusal.principal_unknown(address, principals.map(&:handle))
          end

          # THE CARRIER AT BIRTH: the default the verb
          # asked for, and the STEWARD's `full` entry beside it — rho's
          # entry, never the kernel's (an agent creator's steward is not
          # derived), so the person typing `rho do --restricted` can see what
          # it opened. The steward is read off this home's own row in the
          # principals listing; a home whose row names none opens with the
          # default alone.
          def access_at_birth(workspace, ctx, default)
            own = workspace.principals.find { |principal| principal.public_id == ctx.own_user_public_id }
            steward = own&.steward_public_id
            entries = steward ? [{ user_public_id: steward, level: "full" }] : []
            { default: default, entries: entries }
          end

          # A `direct_reply` whose text is the person's words, queued (the
          # conversation is idle, so it starts at once), on the turn's model
          # with the selection's subset and the turn's approval tightening beside
          # it, opening with the one inline entry — DEVELOPER-role: the environment and the tool lines change per turn and per
          # runner, so they ride behind the memory block, outside the stable
          # prefix the slots and memory make; the guideline is the profile's
          # `system_prompt` slot and needs no entry. Absent when there is
          # nothing to say, which the kernel would refuse as an empty entry.
          # What a `say` turn carries: a side row its posture's subset and the
          # tail; a turn answered by another profile the bare words (`bare` is the addressee's foreignness, named per call or remembered on the row); a plain turn the selection's names. `to`
          # rides whenever one was named; `model` is `say_model`'s answer.
          # `schedule` is the kernel's `deliver_at`/`deliver_in` as typed, on
          # every shape of turn alike.
          # Explicit tool names and approval tightening belong to the
          # addressed turn; the kernel validates them against that answerer's
          # declaration. Only an omitted subset uses rho's selection, and a bare
          # turn has no rho defaults. A side permits only a further subset
          # of its posture's names and keeps its approval tightening.
          def say_fields(host, row, text, mode:, selection:, side:, bare:, model:, to: nil, attachments: [], schedule: {},
                         approval_mode: nil, tool_names: nil)
            pictures = attachments.empty? ? nil : attachments
            unless bare || tool_names.nil?
              tool_names = Array.try_convert(tool_names)
              return Refusal.malformed("tool_names must be a list") if tool_names.nil?

              tool_names = tool_names - selection.blocked_names
            end
            return side_fields(host, row, text, mode: mode, model: model, selection: selection, attachments: pictures,
              schedule: schedule, tool_names: tool_names, approval_mode: approval_mode) if side
            names = tool_names.nil? ? (selection.tool_names unless bare) : tool_names
            host.input_fields(text, mode: mode, model: model, tool_names: names, to: to,
              approval_mode: approval_mode, attachments: pictures, **schedule)
          end

          # THE MODEL A CONVERSATION'S `say` RIDES, in
          # one order: the row's own — the flag or the settings' default that
          # opened it, the model it last replied on — else the settings'
          # `default_model` (rho's own preset, the fact it declared), else THE
          # ADDRESSED TURN'S: the run projection's `turn.model`, the stated
          # place the kernel carries the model in use (the answerer's preset,
          # else the initiator's) — a conversation another agent spawned rho
          # into remembers no model, and this is where it reads one. Nil only
          # when the wire carries none either, which `say` refuses rather
          # than posting a row the kernel would park `model_selection_missing`.
          MODEL_REQUIRED_ON_SAY = "model is required, as provider/reference: this row was not opened here, " \
            "the settings name no default_model, and its turn carries no model".freeze

          def say_model(row, workspace)
            [row.model, @config.default_model].map(&:to_s).find { |word| !word.empty? } ||
              addressed_turn_model(row, workspace)
          end

          def addressed_turn_model(row, workspace)
            return nil if row.run_public_id.nil?

            workspace.run(row.run_public_id).fetch.turn&.model_ref
          rescue CybrosAgent::Error => error
            @log.warn("say.turn_model_unread", host: row.host.public_id, run: row.run_public_id,
              error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
            nil
          end

          # `bare` (a foreign answerer) sends the words and the
          # model alone: the subset, the tightening and the lead describe
          # THIS machine's tools and would be judged against the addressee's.
          # The pictures (`attachments`, the staged ids) ride either way.
          def reply_fields(host, draft, selection, bare: false)
            pictures = Array(draft.body["attachments"])
            pictures = nil if pictures.empty?
            if bare
              return host.input_fields(draft.body.fetch("prompt").to_s, mode: "queue", model: draft.body.fetch("model"),
                attachments: pictures)
            end

            fields = host.input_fields(draft.body.fetch("prompt").to_s, mode: "queue",
              model: draft.body.fetch("model"), tool_names: selection.tool_names,
              approval_mode: draft.body["approval_mode"], attachments: pictures)
            return fields if draft.lead.empty?

            fields.merge(inline: [{ "role" => "developer", "position" => "lead", "text" => draft.lead }])
          end

          def input_speaker(client, ctx, body)
            body.fetch("speaker_public_id") do
              if @owner_speaker.nil? || @owner_speaker.channel_key != "rho:#{ctx.own_user_public_id}"
                @owner_speaker = Speakers.owner(client: client, agent_public_id: ctx.own_user_public_id)
              end
              @owner_speaker.public_id
            end
          end

          def external_named_answerer?(answerer)
            !answerer.nil? && @named_edge.plan.settings[answerer.name]&.audience == "external"
          end

          # Another application's answerer does not inherit this home's Runner;
          # only an explicit selection crosses that boundary for Nexus to judge.
          def opening_runner(body, ctx, foreign:, named_answerer:)
            return nil if external_named_answerer?(named_answerer)
            return nil if foreign && !named_answerer && !body.key?("default_runner_executor_public_id")

            ctx.runner_selection(body)
          end

          def input_memory_context(client, ctx, body)
            body.fetch("memory_context") do
              Speakers.memory_context
            end
          end

          def attachments_present?(body)
            Array(body["attachments"]).any? || Array(body["upload_public_ids"]).any?
          end

          def title_after_input(host, hosted, accepted, workspace, text:, model:, blocked: false)
            return unless host.outlives_turn?

            @titles.accept(policy: policy_for(host, hosted), conversation: hosted, input: accepted, workspace: workspace,
              text: text, model: model, blocked: blocked || accepted.input.state == "blocked", spawn: ->(&task) { @context.spawn(&task) })
          end

          # Ingress adapters can prepare an upload once and retain its ID with
          # their input key. The kernel owns upload authorization and binding;
          # resolving or uploading again here would change a replay's envelope.
          def input_attachments(client, body, ctx)
            ids = Array(body["upload_public_ids"])
            if ids.any? && Array(body["attachments"]).any?
              return Refusal.malformed("cannot combine attachments paths with upload_public_ids")
            end
            return stage_attachments(client, body["attachments"], ctx) if ids.empty?

            Staged.new(ids: ids, descriptors: [])
          end

          # THE PICTURES, STAGED: each path the verb posted is
          # resolved the way `Rho::Runner::Files` and the tools resolve one — expanded
          # against the environment root, no confinement (a bearer holding
          # this door authors a `bash` that reads anything this user can) —
          # read, and uploaded through the member plane as rho's own user;
          # the kernel sniffs the bytes and answers the descriptor. A path
          # that is not a file is refused by name before any byte moves; a
          # kernel refusal (the size bound) relays as itself.
          def stage_attachments(client, paths, ctx)
            return Staged.none if paths.nil?

            paths = Array.try_convert(paths)&.map { |path| String.try_convert(path) }
            return Refusal.malformed("attachments must be a list of file paths") unless
              paths && paths.none?(&:nil?)

            root = ctx.environment.root
            files = paths.map { |path| File.expand_path(path, root) }
            missing = paths.zip(files).find { |_path, file| !File.file?(file) }
            if missing
              return Refusal.new(status: 422, code: "attachment_unreadable",
                message: "No such file to attach: #{missing.first}")
            end

            uploads = files.map { |file| client.uploads.create(file) }
            Staged.new(ids: uploads.map(&:public_id), descriptors: uploads.map do |upload|
              { filename: upload.filename, content_type: upload.content_type, byte_size: upload.byte_size }
            end)
          end
      end
    end
  end
end
