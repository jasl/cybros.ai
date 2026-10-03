module Rho
  module Acp
    class Agent
      # THE REPLAY: nothing of ACP's is stored — no
      # mapping file, no session table — so `session/load` reads the
      # conversation back off the kernel through the core: `Core#turns`
      # paged to the end; per turn ONE EXCHANGE. A reply turn (role
      # assistant — every `say` materializes one, the person's words on
      # its seed) replays a `user_message_chunk` from the variant's
      # `prompt_text` (absent on a wordless seed, then no chunk), for a loop-backed reply
      # `Core#transcript(agent_loop_public_id)` paged — each settled call
      # → `tool_call {toolCallId: "<loop>:<task_key>", title, kind:
      # KIND[name], status: is_error ? failed : completed}` — then an
      # `agent_message_chunk` from its whole `content`. A message turn
      # (role user) replays its `content` as the user's chunk. Then the
      # response. The kernel's own summary turns and every other role are
      # not a person's or the agent's word and are skipped. Replay
      # `messageId`s are `"<turn>:0"`, the exchange's two chunks sharing
      # their turn's. A `$/cancel_request` on the load aborts the replay
      # (-32800).
      #
      # A HELD ASK on the row (`loop_row.attention` = `awaiting_human`) is
      # re-armed AFTER the response: `elicitation/create` when the client
      # has the form (answered through `Core#answer`, the turn then
      # followed on a thread of its own so its updates reach the editor —
      # a thread that HOLDS the session's prompt slot from before it starts
      # until it returns, `Rearm` in sessions.rb, so no `session/prompt`
      # works the same turn beside it: the drain's -32600), else the
      # question as the last replayed chunk and the hold — the way, too,
      # when the slot is already a prompt's (one that raced the load), so
      # a re-arm is never dropped.
      module Replay
        USER = "user".freeze
        ASSISTANT = "assistant".freeze
        SUMMARY = "compaction_summary".freeze
        ASKING = "awaiting_human".freeze

        module_function

        def call(agent, session, core, inbound)
          latest = each_turn(session, core, inbound: inbound) { |turn| replay_turn(agent, session, core, turn) }
          remember(session, latest)
        end

        # A fresh attach may return before its follower has replayed any
        # events. Resume restores the target lazily, without replaying UI.
        def restore(session, core)
          remember(session, each_turn(session, core))
        end

        def each_turn(session, core, inbound: nil)
          after = nil
          latest = nil
          loop do
            raise Refusal.cancelled if inbound&.cancelled?

            document = core.turns(session.id, after_position: after)
            Array(document["turns"]).each do |turn|
              latest = turn if turn["kind"] != SUMMARY && turn["role"] == ASSISTANT
              yield turn if block_given?
            end
            pagination = Hash.try_convert(document["pagination"]) || {}
            break unless pagination["has_more"]

            after = pagination["after_position"]
          end
          latest
        end

        def remember(session, turn)
          return if turn.nil?

          session.last_turn = turn["public_id"]
          session.last_loop = turn.dig("active_variant", "agent_loop_public_id")
          nil
        end

        def replay_turn(agent, session, core, turn)
          return if turn["kind"] == SUMMARY

          variant = Hash.try_convert(turn["active_variant"]) || {}
          content = variant["content"]
          message_id = "#{turn["public_id"]}:0"
          case turn["role"]
          when USER
            chunk(agent, session, Acp::Methods::SessionUpdate::USER_MESSAGE_CHUNK, content, message_id)
          when ASSISTANT
            chunk(agent, session, Acp::Methods::SessionUpdate::USER_MESSAGE_CHUNK, variant["prompt_text"], message_id)
            calls(agent, session, core, variant["agent_loop_public_id"]) if variant["agent_loop_public_id"]
            chunk(agent, session, Acp::Methods::SessionUpdate::AGENT_MESSAGE_CHUNK, content, message_id)
          else nil
          end
        end

        def chunk(agent, session, kind, content, message_id)
          content = String.try_convert(content)
          return if content.nil? || content.empty?

          update(agent, session, kind, "content" => { "type" => "text", "text" => content }, "messageId" => message_id)
        end

        # The thread newest-first, paged to its oldest, then read forward.
        def calls(agent, session, core, loop_id)
          rounds = []
          before = nil
          loop do
            page = core.transcript(loop_id, before: before)
            rounds.concat(Array(page["rounds"]))
            break unless page["has_older"]

            before = page["next_before"]
          end
          rounds.reverse_each do |round|
            Array(Hash.try_convert(round["calls"])&.dig("items")).each { |row| replay_call(agent, session, loop_id, row) }
          end
        rescue Rho::Error => error
          agent.say("the calls of #{loop_id} could not be replayed (#{error.message})")
        end

        def replay_call(agent, session, loop_id, row)
          row = Hash.try_convert(row)
          return unless row && row["task_key"]

          name = row["name"].to_s
          status = row["is_error"] ? Acp::Methods::ToolCallStatus::FAILED : Acp::Methods::ToolCallStatus::COMPLETED
          update(agent, session, Acp::Methods::SessionUpdate::TOOL_CALL,
            "toolCallId" => "#{loop_id}:#{row["task_key"]}", "title" => name, "kind" => Mapping.kind_of(name),
            "status" => status)
        end

        # THE HELD ASK RE-ARMED, after the response: the form on a thread
        # that claimed the session's prompt slot FIRST (`Rearm`); else — no
        # form, or the slot already a prompt's — the question as the last
        # chunk and the hold, on this thread.
        def rearm(agent, session, core)
          row = core.loop_row(session.id)
          attention = Hash.try_convert(row["attention"]) || {}
          return unless attention["reason"] == ASKING

          key = Array(attention["blocked_task_keys"]).first
          loop_id = row["loop"]
          turn = row["turn"]
          return if key.nil? || loop_id.nil?

          session.last_turn = turn
          session.last_loop = loop_id
          permissions = permissions_of(agent, session, core, turn, loop_id)
          if agent.client.elicitation_form? && session.claim_prompt(Rearm.new(loop: loop_id, key: key, turn: turn))
            Thread.new { rearm_form(agent, session, core, permissions, turn, loop_id, key) }
              .tap { |thread| thread.name = "rho-acp-rearm" }
          else
            permissions.ask_held(loop_id, key)
            session.held = Hold.new(loop: loop_id, key: key, turn: turn)
          end
          nil
        rescue Rho::Error => error
          agent.say("the held ask of #{session.id} could not be re-armed (#{error.message})")
        end

        # The form on its own thread, the slot its own until it returns:
        # answered, the turn is followed on so its updates reach the
        # editor; held when the card was cancelled; nothing when a
        # `session/cancel` cancelled it — the cascade dropped the hold and
        # stopped the turn. The slot is released whatever happened.
        def rearm_form(agent, session, core, permissions, turn, loop_id, key)
          outcome = permissions.ask(loop_id, key)
          return if session.cancel_requested?

          if outcome == :continue
            Turn.catch_up(core, session) { |row| !Turn.asking?(row, key) }
            follow_on(agent, session, core, turn, loop_id)
          else
            session.held = Hold.new(loop: loop_id, key: key, turn: turn)
          end
        rescue Turn::Cancelled
          nil
        rescue StandardError => error
          agent.say("the re-armed ask of #{session.id} failed (#{error.message})")
        ensure
          session.release_prompt
        end

        def follow_on(agent, session, core, turn, loop_id)
          mapping = mapping_of(agent, session, core, turn, loop_id)
          permissions = Permissions.new(agent: agent, session: session, core: core, mapping: mapping)
          Rho::Cli::TurnFollow.new(core: core, conversation: session.id, turn: turn, loop: loop_id,
            on_frame: mapping.method(:frame), on_park: permissions.method(:park)).follow
        end

        def mapping_of(agent, session, core, turn, loop_id)
          Mapping.new(agent: agent, session: session, core: core, state: session.turn_state(turn, loop: loop_id))
        end

        def permissions_of(agent, session, core, turn, loop_id)
          mapping = mapping_of(agent, session, core, turn, loop_id)
          Permissions.new(agent: agent, session: session, core: core, mapping: mapping)
        end

        def update(agent, session, kind, fields)
          agent.connection.notify(Acp::Methods::SESSION_UPDATE,
            "sessionId" => session.id,
            "update" => { Acp::Methods::SESSION_UPDATE_DISCRIMINATOR => kind }.merge(fields))
        rescue Closed
          nil
        end
      end
    end
  end
end
