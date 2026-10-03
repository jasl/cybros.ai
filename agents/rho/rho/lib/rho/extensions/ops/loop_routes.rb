require_relative "loop_routes/records"
require_relative "loop_routes/following"

module Rho
  module Extensions
    module Ops
      # The loop routes behind the operator's verbs: every one reaches the
      # kernel through `ctx.member_plane`, the followers through `ctx.follow`
      # and `ctx.run`. Every verb takes a LOOP id; a loop-backed one resolves
      # to the conversation whose turn it backs. The
      # STANDALONE author (`POST /loops`) and the followed-set reads live
      # here too: debug verbs are an extension, and the core opens
      # conversations.
      module LoopRoutes
        TRANSCRIPT_LIMIT = 20
        LOOP_LIST_LIMIT = 25
        # One inbox page is the daemon's whole pending set: an ask stands
        # until a person answers it, a held call until a person decides it
        # or its clock fires, and a person has fewer than this.
        ASK_PAGE_LIMIT = 200
        # The two kinds a person ends: a question, and a call held for
        # approval. The tool rows beside them are the
        # runner's, never listed here.
        PENDING_KINDS = %w[ask approval].freeze
        # The kernel's word for a row that is not this executor's: a Human-created loop's ask, addressed to nobody.
        NOT_ADDRESSED_HERE = "not_addressed_here".freeze
        # The store note the core writes on a side conversation (`Daemon::Loops::Sides`), read here by its name through
        # `ctx.notes`: an extension reaches the core through the facade alone.
        SIDE_NOTE = "rho.side".freeze
        # How many kernel windows one turns read pages:
        # ten of `Ops::TURN_PAGE` rows — a session an editor replays — under
        # the one kernel-round-trip budget; past it the answer says so.
        TURNS_PAGE_CAP = 10

        class << self
          def register(api)
            api.register_route("POST", "/loops") { |request, ctx| author(request, ctx) }
            api.register_route("GET", "/loops") { |request, ctx| list(request, ctx) }
            api.register_route("GET", "/loops/follow") { |request, ctx| stream(request, ctx) }
            api.register_route("POST", "/loops/attach") { |request, ctx| attach(request, ctx) }
            api.register_route("POST", "/answer") { |request, ctx| answer(request, ctx) }
            api.register_route("GET", "/asks") { |_request, ctx| asks(ctx) }
            api.register_route("POST", "/loops/retry") { |request, ctx| adjudicate(request, ctx, "retry") }
            api.register_route("POST", "/loops/abandon") { |request, ctx| adjudicate(request, ctx, "abandon") }
            api.register_route("POST", "/loops/approve") { |request, ctx| decide(request, ctx, "approve") }
            api.register_route("POST", "/loops/deny") { |request, ctx| decide(request, ctx, "deny") }
            # THE SESSION GRANTS: what `rho rules` reads.
            api.register_route("GET", "/rules") { |_request, ctx| rules(ctx) }
            api.register_route("POST", "/loops/delete") { |request, ctx| delete(request, ctx) }
            api.register_route("POST", "/loops/pause") { |request, ctx| pause(request, ctx) }
            api.register_route("POST", "/loops/resume") { |request, ctx| resume(request, ctx) }
            api.register_route("POST", "/loops/subscribe") { |request, ctx| set_live(request, ctx, true) }
            api.register_route("POST", "/loops/unsubscribe") { |request, ctx| set_live(request, ctx, false) }
            api.register_route("GET", "/loops/result") { |request, ctx| result(request, ctx) }
            api.register_route("GET", "/loops/transcript") { |request, ctx| transcript(request, ctx) }
            api.register_route("GET", "/loops/task") { |request, ctx| task(request, ctx) }
            api.register_route("POST", "/loops/relay") { |request, ctx| relay(request, ctx) }
            api.register_route("GET", "/loops/graph") { |request, ctx| graph(request, ctx) }
            api.register_route("GET", "/loops/request") { |request, ctx| request_read(request, ctx) }
            api.register_route("POST", "/loops/append") { |request, ctx| append(request, ctx) }
            api.register_route("GET", "/loops/phases") { |request, ctx| phases(request, ctx) }
            api.register_route("GET", "/inputs") { |request, ctx| inputs(request, ctx) }
            api.register_route("POST", "/inputs/delete") { |request, ctx| delete_input(request, ctx) }
            api.register_route("POST", "/inputs/update") { |request, ctx| update_input(request, ctx) }
            # THE ACCESS CARRIER: ONE route, PUT — the kernel's door
            # is a whole replacement, and the person's add/rm/default are
            # this route's read-modify-write over the SDK's fetch.
            api.register_route("PUT", "/conversations/access") { |request, ctx| access(request, ctx) }
            # THE PREVIEW: the estimate rendered, through
            # the SDK's one door, and the profile's own slots read.
            api.register_route("POST", "/conversations/prompt_preview") { |request, ctx| prompt_preview(request, ctx) }
            api.register_route("GET", "/prompt/documents") { |request, ctx| prompt_documents(request, ctx) }
            # REWIND / REGENERATE: the door behind `rho rewind` /
            # `rho regenerate` — the SDK's fork-then-restore, and the
            # restore-first regenerate, composed on the member plane.
            api.register_route("POST", "/conversations/rewind") { |request, ctx| rewind(request, ctx) }
            api.register_route("POST", "/conversations/regenerate") { |request, ctx| regenerate(request, ctx) }
            # THE DECK AND ONE CANDIDATE'S VIEW STATE: the
            # live candidates of a turn, and the kernel's `PATCH …/variants/
            # {id}` — conceal or restore a sample — behind `rho variant`.
            api.register_route("GET", "/conversations/variants") { |request, ctx| variants(request, ctx) }
            api.register_route("POST", "/conversations/activate") { |request, ctx| activate_variant(request, ctx) }
            api.register_route("POST", "/conversations/variant") { |request, ctx| variant(request, ctx) }
            # THE REPLAY'S SPINE: the turns listing
            # behind `Core#turns` and `rho turns`, paged to the end here.
            api.register_route("GET", "/conversations/turns") { |request, ctx| turns(request, ctx) }
          end

          # THE STANDALONE LOOP: seeded with the bound runner's tools and the
          # kernel's — in the compose tier the settings give its model, the
          # same resolver `rho do` uses and no flag — the lead as the seed's `instructions` under `raw`, in its
          # prompt under an assembled word — started at once
          # (author and start are separate kernel verbs so a caller can
          # inspect before spending a model call; this verb has decided),
          # and followed on its own feed. No hooks shape it — the `do`
          # flags belong to the conversation the core opens. A runner
          # ELSEWHERE seeds its announced entries and its
          # snapshot in place of this machine's: a seed is the loop's whole
          # tool set, so it must carry the runner's.
          def author(request, ctx)
            ctx.member_plane(request, body: true) do |client, workspace_public_id, about, body|
              prompt = body["prompt"].to_s
              next Rho::Daemon::Refusal.malformed("prompt is required") if prompt.empty?

              model = body["model"].to_s
              next Rho::Daemon::Refusal.malformed("model is required, as provider/reference") if model.empty?

              loops = ctx.loops_for(client, workspace_public_id)
              runner = ctx.runner_selection(body)
              remote = ctx.remote_runner(runner) if runner && !ctx.own_runner?(runner)
              # Every environment field is optional and constrains nothing:
              # the tools decline path confinement.
              environment = remote ? nil : Rho::Runner::Environment.local(
                root: ctx.tool_env.root, working_directory: body["working_directory"]
              )
              # THE SHELL'S MECHANISM: the body's word rides to
              # the kernel's shell as itself (the kernel is the one
              # vocabulary; its refusal relays). Under `default`/`assembly`
              # the seed carries no system field — the guideline is rho's
              # `system_prompt` slot, compiled in by the kernel — and the
              # lead rides ahead of the words in the prompt; under `raw`
              # (unnamed: today's bytes) the system field keeps the lead
              # and the guideline (`LoopRequest.instructions`/`remote_instructions`).
              mechanism = body["prompt_mechanism"]
              assembled = Rho::LoopRequest.assembled?(mechanism)
              # The model's adaptation row's hints ride the seed's lead as
              # they ride a conversation turn's.
              hints = ctx.lead_hints(model)
              lead = if assembled
                remote ? Rho::LoopRequest.remote_lead(remote.environment, instructions: body["instructions"], hints: hints) :
                  Rho::LoopRequest.lead(registry: ctx.registry, environment: environment, instructions: body["instructions"],
                    hints: hints)
              end
              # The explicit default shell uses the kernel's template, not
              # this profile's. Its known kind rides the existing input lead.
              if mechanism == "default"
                lead = Rho::LoopRequest.led(lead, Rho::ExecutionPolicy.context(kind: "standalone"))
              end
              steps = Rho::LoopRequest.steps(
                prompt: assembled ? Rho::LoopRequest.led(lead, prompt) : prompt,
                model: model, registry: ctx.registry, served: remote&.served_tools,
                environment: environment, prompt_mechanism: mechanism,
                # A remote seed's system field is composed whole here, hints
                # inside it; a local one composes it in `steps`.
                hints: (remote ? [] : hints),
                instructions: remote ? Rho::LoopRequest.remote_instructions(remote.environment,
                  instructions: body["instructions"], hints: hints) : body["instructions"],
                kernel_tools: ctx.kernel_tool_definitions(client, model: model)
              )
              # THE SHELL: rho's word is `bypass` by product policy and it is NAMED on every loop this
              # route authors — the kernel refuses nil, nothing is silently defaulted — with the
              # daemon's ONE rule list (the guard list, this install's incubation denies, the session
              # grants — inert under the shell's own `bypass` but for the denies): a standalone loop
              # has the declaring profile's address but its OWN shell, and without the list `rm -rf /`
              # would dispatch to rho's runner where only the floor stands. `--approval` is the
              # conversation's knob; this verb takes none.
              created = loops.create(steps: steps, idempotency_key: body["idempotency_key"] || SecureRandom.uuid,
                approval_mode: Rho::LoopRequest::APPROVAL_MODE,
                approval_rules: ctx.approval_rules,
                **({ prompt_mechanism: mechanism } unless mechanism.nil?),
                **({ runner_executor_public_id: runner } if runner))
              host = Rho::Host::AgentLoop.new(public_id: created.agent_loop.public_id)
              ctx.remember(host, workspace: workspace_public_id, runner: created.agent_loop.runner&.executor_public_id)
              hosted = loops.agent_loop(host.public_id)
              started = hosted.start
              run = follow(ctx, about, host, hosted, loops: loops, live: body["live"] != false,
                stream: body["stream"] != false)
              [201, { loop: HostRun.loop_projection(started), run: run&.snapshot&.to_h,
                      tools: Array(steps.first.tools).map { |entry| entry.dig("function", "name") } }.compact]
            end
          end

          # The followed set is the default (free, local); `scope=server`
          # costs a member-plane request and shows what a restarted daemon
          # no longer follows, so a restart does not look like an empty
          # machine. A followed conversation counts as every loop it backed.
          def list(request, ctx)
            query = ControlServer.query(request)
            return [200, { loops: snapshots(ctx, side: query["side"] == "1") }] unless query["scope"] == "server"

            ctx.member_plane(request) do |client, workspace_public_id|
              followed = hosts(ctx)
              page = ctx.loops_for(client, workspace_public_id).list(
                limit: LOOP_LIST_LIMIT, order: "desc",
                status: query["status"], attention: query["attention"]
              )
              rows = page.items.map do |row|
                { public_id: row.public_id, status: row.status, failure_reason: row.failure_reason,
                  attention: row.attention && { reason: row.attention.reason },
                  followed: followed.any? { |run| run.backs?(row.public_id) },
                  created_at: row.created_at }.compact
              end
              [200, { loops: rows, scope: "server" }]
            end
          end

          # TWO DOORS OVER ONE SETTLE:
          # a `resolution_token` names a client-authored await, which is
          # never an inbox row — the MEMBER door, write standing plus the
          # token. Without one the row is this agent's own inbox `ask`,
          # committed on the EXECUTOR plane with no claim token: the address
          # is the door. A row the executor door refuses `not_addressed_here`
          # — a Human-created loop's ask, addressed to nobody (E7) — falls
          # ONCE to the member door, where rho's bearer has write standing.
          # The answer names which door settled it.
          def answer(request, ctx)
            ctx.loop_command(request) do |loops, public_id, body|
              task_key = body["task_key"].to_s
              next Rho::Daemon::Refusal.malformed("task_key is required") if task_key.empty?

              fields = { content: body["content"].to_s }
              fields[:outcome] = body["outcome"] if body["outcome"].is_a?(String)
              token = body["resolution_token"]
              door =
                if token.is_a?(String) && !token.empty?
                  resolve_at_member_door(loops, public_id, task_key, fields.merge(resolution_token: token))
                else
                  commit_on_executor_plane(ctx, loops, public_id, task_key, fields)
                end
              next door if door in Rho::Daemon::Refusal

              [200, { answered: { public_id: public_id, task_key: task_key, door: door } }]
            end
          end

          def resolve_at_member_door(loops, public_id, task_key, fields)
            loops.agent_loop(public_id).tasks_context(task_key).resolve(**fields)
            "member"
          end

          def commit_on_executor_plane(ctx, loops, public_id, task_key, fields)
            ctx.executor_plane do |executor|
              executor.inbox_task(agent_loop_public_id: public_id, task_key: task_key)
                .commit(claim_token: nil, **fields)
              "executor"
            rescue CybrosAgent::Api::Error => error
              raise unless error.code == NOT_ADDRESSED_HERE

              resolve_at_member_door(loops, public_id, task_key, fields)
            end
          end

          # THE LEVEL-TRIGGERED READ: the daemon's
          # pending rows are the `ask` and `approval` rows of its own inbox —
          # a question a person answers, a call a person decides, each with
          # its clock — never the tool rows beside them. One read lists both
          # kinds, each row named by its kind: an ask carries its question, a
          # held call its tool, its arguments and the effect profile the
          # approver reads.
          def asks(ctx)
            ctx.executor_plane do |executor|
              rows = executor.inbox.list(limit: ASK_PAGE_LIMIT).items.select { |row| PENDING_KINDS.include?(row.kind) }
              [200, { asks: rows.map { |row| pending_row(row) } }]
            end
          end

          # By kind, because the SDK reads an empty `tool_input` on every
          # row: a question carries its prompt, a held call its arguments.
          def pending_row(row)
            detail =
              case row.kind
              when "ask" then { prompt: row.prompt }
              when "approval" then { tool_name: row.tool_name, tool_input: row.tool_input, effect_profile: row.effect_profile }
              else {}
              end
            { kind: row.kind, workspace_public_id: row.workspace_public_id, agent_loop_public_id: row.agent_loop_public_id, task_key: row.task_key,
              **detail, deadline_at: row.deadline_at }.compact
          end

          # THE APPROVAL VERBS: `approve` releases a held call
          # through the kernel's one grant site, `deny` fails it
          # `approval_denied` with the reason the model reads next. The key
          # is ALWAYS named — an approval is a decision about ONE call whose
          # arguments the person has read, and deciding blind is what the
          # stage exists to prevent — so this is not `adjudicate` (which
          # chooses the single repairable row and answers a
          # `failure_resolution` an approval has none of). The answer is the
          # task as the kernel left it: `dispatched` (a runner tool),
          # `running` (a kernel tool), `needs_approval` (the RE-PARK: the
          # effect profile changed under the park) or `failed`,
          # with the stage's fact; the kernel's 409 `not_awaiting_approval`
          # relays as itself.
          def decide(request, ctx, verb)
            ctx.loop_command(request) do |loops, public_id, body|
              task_key = body["task_key"].to_s
              if task_key.empty?
                next Rho::Daemon::Refusal.malformed("task_key is required: name the call the ASKING line printed")
              end

              # THE SESSION GRANT,
              # in order: the held row read, the rule DERIVED — every
              # refusal 400 before anything moves — then the approve, then
              # the grant declared under the declaring gate.
              grant = verb == "approve" ? grant_for(ctx, loops, public_id, task_key, body) : nil
              next grant if grant in Rho::Daemon::Refusal

              context = loops.agent_loop(public_id).tasks_context(task_key)
              reason = body["reason"] if body["reason"].is_a?(String)
              task = verb == "deny" ? context.deny(reason: reason) : context.approve
              answer = { task: { key: task.key, status: task.status, error: task.error,
                                 approval: task.approval }.compact }
              answer[:grant] = grant_answer(ctx.grant(grant), grant) if grant
              [200, answer]
            end
          end

          # THE GRANT TO MAKE, or nil (no flag), or the refusal (400
          # `malformed_body` with the derivation's sentence): `--match`
          # implies `--always`; the held row is read through the member
          # plane's task read (S6) and must be resting `needs_approval`
          # (the kernel's 409 on the approve relays as itself either way);
          # the conversation is the loop's binding's (a standalone loop
          # names none); the time is the daemon's clock.
          def grant_for(ctx, loops, public_id, task_key, body)
            match = body["match"]
            return nil unless body["always"] == true || body.key?("match")
            return Rho::Daemon::Refusal.malformed("match must be a string") unless match.nil? || match.is_a?(String)

            detail = loops.agent_loop(public_id).task(task_key)
            unless detail.task.status == "needs_approval"
              return Rho::Daemon::Refusal.malformed(
                "#{task_key} is not held for approval (#{detail.task.status}); a grant keys on a held call")
            end

            rule = Rho::LoopRequest::Grant.rule(tool_name: detail.task.tool_name, tool_input: detail.tool_input,
              match: match)
            return Rho::Daemon::Refusal.malformed(rule.message) if rule in Rho::LoopRequest::Grant::Refusal

            Rho::LoopRequest::Grant.new(rule: rule, loop: public_id, task_key: task_key,
              conversation: ctx.host_binding(public_id)&.fetch(:host)&.conversation_public_id,
              granted_at: ctx.clock.call.utc.iso8601)
          end

          # ONE WORD for what the grant section answered (X12): `already`,
          # the rule with its time, or the kernel's refusal code — the call
          # ran either way, so the answer is 200 and the CLI derives its line.
          def grant_answer(outcome, grant)
            case outcome
            when :already then { already: true }
            when :declared, :unchanged then { rule: grant.rule, granted_at: grant.granted_at }
            else { refused: outcome.code }
            end
          end

          # THE SESSION GRANTS, numbered by the CLI, with the declared
          # list's size against the kernel's bound — computed locally on the
          # SDK's canonical measure, no kernel read.
          def rules(ctx)
            declared = ctx.approval_rules
            grants = ctx.grants.map do |grant|
              { rule: grant.rule, loop: grant.loop, task_key: grant.task_key, conversation: grant.conversation,
                granted_at: grant.granted_at }.compact
            end
            [200, { grants: grants,
                    declared: { rules: declared.length, bytes: CybrosAgent::SizeBounds.canonical_bytesize(declared),
                                bound: Rho::LoopRequest::Grant::DECLARED_BOUND } }]
          end

          # A halted loop has no clock; it stands until somebody decides. The
          # key is optional because the kernel's adjudicable rule is narrow:
          # one candidate is the one meant, two are refused by name.
          # RETRY ON ANOTHER MODEL: `model`, with `reasoning_effort` beside
          # it, reaches the SDK's `retry(model:)` — the person's way on for
          # a step a provider declined when no fallback took it. An effort
          # tunes the model the task re-runs on, so it needs one; `abandon`
          # re-runs nothing, so a body naming a model there is refused rather
          # than dropped.
          def adjudicate(request, ctx, verb)
            ctx.loop_command(request) do |loops, public_id, body|
              selection = { model: body["model"].to_s, reasoning_effort: body["reasoning_effort"].to_s }
                .reject { |_, value| value.empty? }
              refusal = selection_refusal(verb, selection)
              next refusal if refusal

              tasks_for(loops, public_id, body) do |context, task_key|
                task = context.tasks_context(task_key).public_send(verb, **selection)
                [200, { task: { key: task.key, status: task.status,
                                failure_resolution: task.failure_resolution }.compact }]
              end
            end
          end

          # The tombstone, never a way to stop a run: the kernel refuses a
          # live loop and says so.
          def delete(request, ctx)
            ctx.loop_command(request) do |loops, public_id|
              loops.agent_loop(public_id).delete
              [200, { deleted: { public_id: public_id } }]
            end
          end

          # Getting in a loop's way without ending it.
          def pause(request, ctx)
            ctx.loop_command(request) do |loops, public_id, body|
              [200, { loop: HostRun.loop_projection(loops.agent_loop(public_id).pause(force: body["force"] == true)) }]
            end
          end

          def resume(request, ctx)
            ctx.loop_command(request) do |loops, public_id|
              [200, { loop: HostRun.loop_projection(loops.agent_loop(public_id).resume) }]
            end
          end

          # The output subscription follows attention: unsubscribed is
          # lifecycle-only on the shared connection. `changed` tells "I
          # attached it" from "it already was".
          def set_live(request, ctx, live)
            body = ControlServer.json_body(request)
            public_id = body.fetch("public_id").to_s
            run = ctx.run(public_id)
            return Rho::Daemon::Refusal.not_followed(public_id, lane: :loop) unless run&.host?

            changed = live ? run.attach_socket : run.detach_socket
            [200, { loop: run.snapshot.to_h, changed: changed }]
          rescue KeyError => error
            Rho::Daemon::Refusal.parameter_missing(error.key)
          end

          # Fetched from the deliverable task's own body — the follower keeps
          # no text. A loop with no deliverable is an honest answer, not an error.
          def result(request, ctx)
            public_id = ControlServer.query(request)["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              context = ctx.loops_for(client, workspace_public_id).agent_loop(public_id)
              agent_loop = context.fetch
              key = agent_loop.deliverable_task_key
              output = key && context.task(key).output
              [200, { result: { public_id: public_id, status: agent_loop.status,
                                task_key: key, output: output }.compact }]
            end
          end

          # Proxied, because the daemon is the only thing on this machine
          # holding a credential: the thread's rounds newest-first behind an
          # opaque cursor, or one branch's under `prefix` (a call key).
          def transcript(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            prefix = query["prefix"].to_s
            ctx.member_plane(request) do |client, workspace_public_id|
              transcript = ctx.loops_for(client, workspace_public_id).agent_loop(public_id).transcript(
                limit: Integer(query.fetch("limit", TRANSCRIPT_LIMIT), exception: false) || TRANSCRIPT_LIMIT,
                before: query["before"], prefix: (prefix unless prefix.empty?)
              )
              [200, { transcript: { rounds: transcript.rounds.map(&:to_h),
                                    next_before: transcript.next_before,
                                    has_older: transcript.has_older } }]
            end
          end

          # One task, whole; `rho result` reads the deliverable, this reads
          # any of them.
          def task(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            task_key = query["task_key"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("task_key is required") if task_key.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              detail = ctx.loops_for(client, workspace_public_id).agent_loop(public_id).task(task_key)
              [200, { task: task_row(detail) }]
            end
          end

          # THE RELAY REQUEST, the verb's door: the body judged,
          # then `Ops.relay` — the one composition every relayed read here
          # takes — answered whole once the task is terminal.
          def relay(request, ctx)
            body = ControlServer.json_body(request)
            tool = body["tool"].to_s
            return Rho::Daemon::Refusal.malformed("tool is required") if tool.empty?

            input = body.fetch("input", {})
            return Rho::Daemon::Refusal.malformed("input must be a JSON object") unless input.is_a?(Hash)

            runner = ctx.runner_selection(body)
            return Rho::Daemon::Refusal.malformed("a relay needs a runner: name one, or select one in the settings") if runner.nil?

            timeout_ms = body["timeout_ms"]
            return Rho::Daemon::Refusal.malformed("timeout_ms must be a positive integer") unless
              timeout_ms.nil? || (timeout_ms.is_a?(Integer) && timeout_ms.positive?)

            relayed = Ops.relay(ctx, runner, tool, input, timeout_ms,
              idempotency_key: body["idempotency_key"] || SecureRandom.uuid)
            return relayed if relayed in Rho::Daemon::Refusal

            [200, { relay: { public_id: relayed.public_id, task: task_row(relayed.detail) } }]
          end

          # The task read's one row, shared by the task route and the relay's
          # answer. The addressee with its presence:
          # what `rho watch` reads for a dispatched call nobody claims.
          def task_row(detail)
            { key: detail.task.key, kind: detail.task.kind,
              status: detail.task.status, tool_name: detail.task.tool_name,
              prompt: detail.prompt, output: detail.output,
              # The settled call's bounded preview, what its feed item
              # carried, for a reader that attached after it settled.
              output_preview: detail.output_preview,
              # The result's blocks: a `resource_link` names a
              # capture `rho fetch` reads; the text beside it is `output`.
              content: detail.content,
              # The tool's structured answer (MCP's `structuredContent`),
              # when the executor sent one: what `rho-dev relay R
              # environment_bind` reads a runner's received binding back
              # as (`{applied, resolved, booted_at}`).
              structured_content: detail.structured_content,
              tool_input: detail.tool_input,
              # The kernel's outcome summary (`is_error` on a tool row):
              # a `completed, is_error` call told apart from a write that
              # landed (the checklist's read).
              result: detail.task.result,
              # The UI's two fields: the header
              # and the carrier, when the executor sent them.
              title: detail.title, metadata: detail.metadata,
              addressed_to: detail.task.addressed_to&.to_h,
              error: detail.task.error,
              # The stage's fact: who or what let
              # the call past, and when; absent until decided.
              approval: detail.task.approval }.compact
          end

          # The picture of a run, proxied whole: nodes, edges and the Mermaid
          # text the kernel drew, for a terminal to print and a page to draw.
          def graph(request, ctx)
            public_id = ControlServer.query(request)["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              graph = ctx.loops_for(client, workspace_public_id).agent_loop(public_id).graph
              [200, { graph: { nodes: graph.nodes.map(&:to_h), edges: graph.edges.map(&:to_h),
                               mermaid: graph.mermaid } }]
            end
          end

          # THE DEBUG DOOR, proxied: the bytes a round or
          # a turn was sent — EXACTLY the sealed entries and the request
          # options, derived from the sealed body, never re-assembled. Two
          # readings by the query: `task_key` reads the round through the
          # loop door (a conversation id resolves to its backing loop, as
          # every loop-grain verb does); `turn` reads the turn's ACTIVE
          # variant through its deck. The kernel's 404 `request_not_sealed`
          # (a tool row, a reply that never minted) relays as itself.
          def request_read(request, ctx)
            query = ControlServer.query(request)
            public_id = query["public_id"].to_s
            task_key = query["task_key"].to_s
            turn = query["turn"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?
            return Rho::Daemon::Refusal.malformed("task_key or turn is required") if task_key.empty? && turn.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              sealed =
                if turn.empty?
                  ctx.loops_for(client, workspace_public_id).agent_loop(ctx.backing_loop(public_id))
                    .tasks_context(task_key).request
                else
                  turns = client.workspace(workspace_public_id).conversation(public_id).turns
                  active = turns.variants(turn).active
                  if active.nil?
                    next Rho::Daemon::Refusal.new(status: 404, code: "request_not_sealed",
                      message: "This turn has no active variant")
                  end

                  turns.request(turn, active.public_id)
                end
              [200, { request: { entries: sealed.entries, request_options: sealed.request_options } }]
            end
          end

          # GROW A LOOP FROM A TERMINAL: the steps as the door reads them,
          # verbatim, placed after the loop's answer. The receipt comes back
          # whole — what was accepted, the mirror, and the new answer.
          def append(request, ctx)
            ctx.loop_command(request) do |loops, public_id, body|
              steps = body["steps"]
              next Rho::Daemon::Refusal.malformed("steps must be an array") unless steps.is_a?(Array)

              fields = { steps: steps, idempotency_key: body["idempotency_key"] || SecureRandom.uuid }
              fields[:resolve] = body["resolve"] if body.key?("resolve")
              fields[:expected_revision] = body["expected_revision"] if body.key?("expected_revision")
              receipt = loops.agent_loop(public_id).append(**fields)
              [201, { receipt: { accepted_task_keys: receipt.accepted_task_keys, steps: receipt.steps,
                                 deliverable_task_key: receipt.deliverable_task_key,
                                 revision: receipt.revision, replayed: receipt.replayed? }.compact }]
            end
          end

          # How far a loop has come, proxied: the phases in write order, the
          # one in flight, the background work and the spend.
          def phases(request, ctx)
            public_id = ControlServer.query(request)["public_id"].to_s
            return Rho::Daemon::Refusal.malformed("public_id is required") if public_id.empty?

            ctx.member_plane(request) do |client, workspace_public_id|
              phases = ctx.loops_for(client, workspace_public_id).agent_loop(public_id).phases
              [200, { phases: { phases: phases.phases.map(&:to_h), current: phases.current,
                                background: phases.background.map(&:to_h), spend: phases.spend } }]
            end
          end

          private

            # `abandon` with a model, or an effort with no model: refused by
            # name before any kernel read.
            def selection_refusal(verb, selection)
              if verb == "abandon" && !selection.empty?
                return Rho::Daemon::Refusal.malformed("abandon re-runs nothing, so it takes no model; retry names one")
              end
              if selection.key?(:reasoning_effort) && !selection.key?(:model)
                return Rho::Daemon::Refusal.malformed(
                  "reasoning_effort needs model: an effort tunes the model the task re-runs on"
                )
              end

              nil
            end

            # A named key is taken as given; without one the trace decides,
            # using the kernel's own rule.
            def tasks_for(loops, public_id, body)
              context = loops.agent_loop(public_id)
              task_key = body["task_key"].to_s
              if task_key.empty?
                candidates = context.fetch.repairable_tasks.map(&:key)
                if candidates.empty?
                  return Rho::Daemon::Refusal.new(status: 409, code: "nothing_to_repair",
                    message: "No task on this loop has an unresolved failure")
                end
                if candidates.length > 1
                  return Rho::Daemon::Refusal.new(status: 409, code: "ambiguous_repair",
                    message: "Name one of: #{candidates.join(", ")}")
                end
                task_key = candidates.first
              end
              yield(context, task_key)
            end
        end
      end
    end
  end
end
