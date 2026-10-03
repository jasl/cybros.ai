require "json"

module Rho
  module Dev
    # THE CONVERSATION-GRAIN VERBS: a repair now (`compact`), the question
    # beside the work (`btw`, `side`), the queue (`inputs`), who may see it
    # (`conversation participants`), the branch and the redo (`rewind`,
    # `regenerate`), the deck (`variant`), the spine (`turns`).
    module Conversations
      QUEUE_VERBS = %w[rm edit].freeze
      ACCESS_VERBS = %w[add rm default].freeze
      ACCESS_USAGE = "`rho conversation participants ID [add PRINCIPAL LEVEL | rm PRINCIPAL | default LEVEL]` " \
        "(PRINCIPAL is @handle or a public id)".freeze

      def self.register(api)
        # A REPAIR VERB, this gem's and not core:
        # the route is the core's (`POST /compact`, the store is the
        # core's), the terminal spelling is here. The exception rule — a
        # repair verb a runner-mode rho needs stays core — names nothing:
        # runner mode drops the conversation verbs and compacts nothing.
        api.register_command("compact", usage: "compact ID [TASK_KEY]",
          description: "Compact a loop or conversation this daemon follows: a conversation's running reply is " \
                       "repaired on its next round (idle, its history is summarized); a loop needs the round's key",
          &method(:compact))
        api.register_command("btw", usage: "btw QUESTION",
          description: "Ask a question beside the running work, on its side conversation; the parent's tools are " \
                       "declared (the provider's cache holds) and any call it makes is denied",
          options: { on: { type: :string, desc: "The conversation to ask beside (default: the newest one this daemon follows)" } },
          &method(:btw))
        api.register_command("side", usage: "side [ID]",
          description: "Open (or resume) the side conversation of a conversation this daemon follows, read-only tools; " \
                       "then `rho say <side-id>`",
          &method(:side))
        api.register_command("inputs",
          usage: "inputs ID | inputs rm ID INPUT_ID | inputs edit ID INPUT_ID [TEXT]",
          description: "The inputs parked or waiting on a host this daemon follows; rm drops one (a scheduled " \
                       "row's cancel), edit rewrites one (the unblock path) or reschedules it",
          # NOT BEFORE A TIME: the
          # kernel's two fields as typed, and `--now` the typed clear
          # (`deliver_in: "0s"`); one of the three, TEXT optional beside it.
          options: {
            at: { type: :string, banner: "TIME",
                  desc: "Reschedule to this ISO 8601 time (with an offset, or in this terminal's zone)" },
            in: { type: :string, banner: "DURATION", desc: "Reschedule to this delay from now (90s, 20m, 2h, 1d)" },
            now: { type: :boolean, default: false, desc: "Make a scheduled row due now" },
          },
          &method(:inputs))
        # THE ACCESS CARRIER FROM A TERMINAL: the listing, and the
        # three re-cuts a person makes — each a whole replacement on the
        # kernel's door, the read-modify-write done there (two adds racing
        # lose one). Conversations of this daemon's adopted workspace alone:
        # the member plane the daemon holds is that workspace's.
        # The usage's alternatives each repeat the verb: exe/rho's Arity
        # reads them apart on `|` before it reads a bracket, so a `[a | b]`
        # spelling would refuse the bare listing form at the door.
        api.register_command("conversation",
          usage: "conversation participants ID | conversation participants ID add PRINCIPAL LEVEL | " \
                 "conversation participants ID rm PRINCIPAL | conversation participants ID default LEVEL",
          description: "Who may see a conversation of this daemon's workspace: print the default and the named " \
                       "entries (@handle, id, kind, name, level), add or drop one, or change the default (full, " \
                       "read, none); PRINCIPAL is @handle or a public id — this listing, `rho status` (handle:, " \
                       "profile:) and the workspace's principals name them — two racing adds keep one",
          &method(:conversation))
        # REWIND / REGENERATE: fork-then-restore, and the lifted
        # regenerate that restores first. Both drive the SDK's composition
        # through the daemon; `--keep-world` forks (or regenerates) without
        # putting the files back.
        api.register_command("rewind", usage: "rewind CONVERSATION_ID TURN",
          description: "Branch a conversation at a turn and put the files back to that point: fork, then restore " \
                       "the world through the child's bound runner (--keep-world forks alone); TURN is a turn id " \
                       "or a bare position",
          options: {
            "keep-world": { type: :boolean, default: false, desc: "Fork without restoring the world" },
            title: { type: :string, desc: "A title for the child conversation" },
          }, &method(:rewind))
        api.register_command("regenerate", usage: "regenerate CONVERSATION_ID TURN",
          description: "Regenerate a loop-backed turn's reply, restoring the world it changed first so the model " \
                       "re-does the work on the same tree (--keep-world regenerates on the world as it is); TURN " \
                       "is the tail turn's id or position",
          options: {
            "keep-world": { type: :boolean, default: false, desc: "Regenerate without restoring the world" },
            model: { type: :string, desc: "provider/reference for the new candidate (default: the turn's own)" },
          }, &method(:regenerate))
        # THE DECK FROM A TERMINAL (CLI alongside the capability): a turn's candidates, and the kernel's view-state door
        # on one of them — conceal a sample, restore it.
        # THE REPLAY'S SPINE FROM A TERMINAL: what `session/load` reads, printed.
        api.register_command("turns", usage: "turns CONVERSATION_ID",
          description: "A conversation's turns in position order (the replay's spine): the position, the id, the " \
                       "role, the kind, the status, the backing loop and the words; the daemon pages the kernel's " \
                       "window to the end under a cap, and `more:` names the next window",
          options: {
            after: { type: :numeric, desc: "Read the turns past this position (the `more:` line names it)" },
            limit: { type: :numeric, desc: "At most this many turns" },
            json: { type: :boolean, default: false, desc: "Print the turns document as JSON" },
          }, &method(:turns))
        api.register_command("variant", usage: "variant CONVERSATION_ID TURN [VARIANT]",
          description: "A turn's live candidates (the active one starred); with a VARIANT id and --conceal or " \
                       "--restore, hide that sample or bring it back — the active one refuses (activate another " \
                       "first), a restore into a retaken slot refuses honestly",
          options: {
            conceal: { type: :boolean, default: false, desc: "Conceal the named candidate" },
            restore: { type: :boolean, default: false, desc: "Restore the named candidate" },
          }, &method(:variant))
        api.register_command("activate", usage: "activate CONVERSATION_ID TURN VARIANT",
          description: "Choose a settled candidate as the turn's answer; the kernel cancels unfinished work " \
                       "owned by the replaced candidate, keeping its completed results",
          &method(:activate))
      end

      class << self
        # Compact now: the host picks the door — a
        # conversation compacts its running reply's next round, or its
        # history when idle; a standalone loop compacts ONE named round (the
        # key is required: there is no "obvious" round to summarize the way
        # there is an obvious failed task to retry). The daemon's core
        # `/compact` route, this verb its terminal spelling.
        def compact(cli, (public_id, task_key), _options)
          compacted = cli.core.compact(public_id, task_key)
          cli.out.puts "compacted: #{compacted.fetch("public_id")} (#{compacted.fetch("host_type")})"
          cli.out.puts "task:      #{compacted["task_key"]}" if compacted["task_key"]
          cli.out.puts "summary:   #{compacted["summary_task_key"]}" if compacted["summary_task_key"]
          compacted
        end

        # `rho btw QUESTION`: a question beside the
        # work — one `/side` with the question under the `none` posture
        # (the parent's tools declared, no call runs: the daemon denies
        # every park) on the parent's one open side (the newest live
        # conversation, or `--on ID`), then the side's stream printed as
        # plain text and NOTHING else: no task table, no status line, no
        # end marker. A person asked a question and gets the answer, while
        # `rho do` runs on.
        def btw(cli, (question), options)
          raise Rho::Error, "btw needs a QUESTION" if question.to_s.strip.empty?

          answer = cli.core.open_side(parent: options[:on], text: question, tools: "none")
          print_side_reply(cli, answer.dig("side", "public_id"))
          answer
        end

        # `rho side [ID]`: open or resume the parent's one open side with
        # rho's read-only posture; the person talks in it with `rho say`.
        def side(cli, (public_id), _options)
          answer = cli.core.open_side(parent: public_id, tools: "read")
          side_id = answer.dig("side", "public_id")
          cli.out.puts "side:      #{side_id} (#{answer["reused"] ? "open" : "opened"})"
          cli.out.puts "parent:    #{answer.dig("parent", "public_id")}"
          cli.out.puts "lead:      #{answer.fetch("lead")}"
          cli.out.puts "talk:      rho say #{side_id} \"…\""
          answer
        end

        # THE QUEUE FROM A TERMINAL: `inputs ID` lists a followed
        # host's rows so a person can find the one the kernel parked;
        # `inputs rm ID INPUT` drops it, `inputs edit ID INPUT TEXT`
        # rewrites it — the unblock path. The subword is the first
        # argument, and any other word is refused before the wire.
        def inputs(cli, (first, *rest), options)
          return list_inputs(cli, first) if rest.empty?
          unless QUEUE_VERBS.include?(first)
            raise Rho::Error, "inputs takes rm or edit before the ids: `rho inputs rm ID INPUT`, `rho inputs edit ID INPUT TEXT`"
          end

          public_id, input_public_id, text = rest
          raise Rho::Error, "inputs #{first} needs ID and INPUT — the ids `rho inputs ID` printed" if input_public_id.to_s.empty?

          return remove_input(cli, public_id, input_public_id) if first == "rm"

          schedule = edit_schedule(options)
          if text.to_s.strip.empty? && schedule.empty?
            raise Rho::Error, "inputs edit needs the new TEXT, or --at TIME | --in DURATION | --now"
          end

          edit_input(cli, public_id, input_public_id, text, schedule)
        end

        # WHO MAY SEE A CONVERSATION, from a terminal: the listing,
        # or one re-cut — add (or re-level) a principal, drop one, change
        # the default — over ONE daemon route, a whole replacement of the
        # kernel's carrier with the read-modify-write done there; two
        # racing adds keep one. The conversation is one of this daemon's
        # adopted workspace.
        def conversation(cli, (word, public_id, verb, *rest), _options)
          raise Rho::Error, "conversation takes participants: #{ACCESS_USAGE}" unless word == "participants"
          raise Rho::Error, "conversation participants needs ID — the conversation `rho do` printed" if public_id.to_s.empty?

          change = verb.nil? ? nil : access_change(verb, rest)
          print_access(cli, cli.core.replace_access(public_id, change))
        end

        # REWIND: branch a conversation at a turn and put the
        # files back to that point. Prints the child, the turn it forked
        # at, and what the restore did — and exits non-zero when the world
        # could not be restored (the child exists; the line says so).
        def rewind(cli, (public_id, turn), options)
          raise Rho::Error, "rewind needs CONVERSATION_ID and TURN" if public_id.to_s.empty? || turn.to_s.empty?

          rewind = cli.core.rewind(public_id, turn, keep_world: options[:"keep-world"] == true, title: options[:title])
          world = rewind.fetch("world")
          cli.out.puts "conversation: #{rewind.fetch("conversation")}"
          position = rewind["position"] ? " (position #{rewind["position"]})" : ""
          cli.out.puts "forked_from:  #{rewind.fetch("forked_from")}#{position}"
          cli.out.puts "world:        #{world_line(world)}"
          raise Rho::Error, "the world could not be restored: #{world["reason"]}" if world.fetch("status") == "failed"

          rewind
        end

        # REGENERATE: re-do a loop-backed tail turn's reply,
        # restoring the world it changed first. Prints the turn, the new
        # candidate and what the restore did; a door that refused AFTER
        # the restore prints the undo and exits non-zero.
        def regenerate(cli, (public_id, turn), options)
          raise Rho::Error, "regenerate needs CONVERSATION_ID and TURN" if public_id.to_s.empty? || turn.to_s.empty?

          regenerate = cli.core.regenerate(public_id, turn, keep_world: options[:"keep-world"] == true,
            model: options[:model])
          world = regenerate.fetch("world")
          cli.out.puts "turn:      #{regenerate.fetch("turn")}"
          cli.out.puts "variant:   #{regenerate["variant"]}" if regenerate["variant"]
          cli.out.puts "world:     #{world_line(world)}"
          if world["door_refused"]
            undo = world["undo"] ? " (undo #{world["undo"]})" : ""
            raise Rho::Error, "the world was restored#{undo} but the door refused: #{world["door_refused"]}"
          end

          regenerate
        end

        # `rho variant CONVERSATION_ID TURN [VARIANT]`: the
        # turn's deck — each candidate's id, source, status, the active
        # mark and a preview — or, naming one with `--conceal`/`--restore`,
        # the kernel's view-state door on that candidate. A concealed
        # sample leaves the deck's listing (`.live`); `--restore` needs
        # the id a person kept.
        def variant(cli, (public_id, turn, variant_id), options)
          raise Rho::Error, "variant needs CONVERSATION_ID and TURN" if public_id.to_s.empty? || turn.to_s.empty?

          conceal = options[:conceal] == true
          restore = options[:restore] == true
          raise Rho::Error, "variant takes --conceal or --restore, not both" if conceal && restore
          return variant_deck(cli, public_id, turn) if variant_id.to_s.empty? && !conceal && !restore
          raise Rho::Error, "variant needs the VARIANT id to --conceal or --restore" if variant_id.to_s.empty?
          raise Rho::Error, "variant needs --conceal or --restore with a VARIANT id" unless conceal || restore

          written = cli.core.variant(public_id, turn, variant_id, concealed: conceal)
          cli.out.puts "variant:   #{written.fetch("public_id")} #{conceal ? "concealed" : "restored"}"
          written
        end

        def activate(cli, (public_id, turn, variant_id), _options)
          if public_id.to_s.empty? || turn.to_s.empty? || variant_id.to_s.empty?
            raise Rho::Error, "activate needs CONVERSATION_ID, TURN and VARIANT"
          end

          written = cli.core.activate_variant(public_id, turn, variant_id)
          cli.out.puts "variant:   #{written.fetch("public_id")} active"
          written
        end

        # `rho turns ID [--after N] [--limit N] [--json]`: one line per
        # turn — under a reply turn the `said:` line, the words that
        # opened it — then the next window's verb when more stands past
        # the cap.
        def turns(cli, (public_id), options)
          raise Rho::Error, "turns needs CONVERSATION_ID — the conversation `rho do` printed" if public_id.to_s.empty?

          after = options[:after]&.to_i
          document = cli.core.turns(public_id, after_position: after, limit: options[:limit]&.to_i)
          return document.tap { cli.out.puts JSON.pretty_generate(document) } if options[:json]

          rows = document.fetch("turns")
          cli.out.puts "(no turns#{after ? " past position #{after}" : ""})" if rows.empty?
          rows.each do |turn|
            cli.out.puts turn_line(cli, turn)
            said = said_line(cli, turn)
            cli.out.puts said if said
          end
          pagination = document.fetch("pagination")
          if pagination["has_more"]
            cli.out.puts "more:      rho turns #{public_id} --after #{pagination["after_position"]}"
          end
          document
        end

        private

          # One turn as a line: the position in a column, the id, the role,
          # the kind, the status, the backing loop when the reply minted
          # one, and the WORDS WHOLE, folded onto the line (this is the replay's spine, and a width that cut the words hid the ones a reader looks for; `--json` is the document itself).
          def turn_line(cli, turn)
            variant = turn["active_variant"] || {}
            parts = [turn.fetch("position").to_s.rjust(4), turn.fetch("public_id"), turn.fetch("role"), turn.fetch("kind"),
                     turn.fetch("status")]
            parts << "loop #{variant["agent_loop_public_id"]}" if variant["agent_loop_public_id"]
            words = variant["content"].to_s.gsub(/\s+/, " ").strip
            parts << %("#{cli.unbounded(words)}") unless words.empty?
            parts.join("  ")
          end

          # THE WORDS THAT OPENED A REPLY TURN: the variant's `prompt_text`,
          # the person's words off the reply's seed, folded whole like the
          # reply's own. Its own line UNDER the turn's row, indented to the
          # id column — the row keeps its documented columns (the lanes
          # parse them) and the words read as that turn's. Absent on a
          # message turn (its content IS the person's words) and on a
          # wordless seed: no line.
          def said_line(cli, turn)
            said = (turn["active_variant"] || {})["prompt_text"].to_s.gsub(/\s+/, " ").strip
            return if said.empty?

            %(      said: "#{cli.unbounded(said)}")
          end

          # The side's stream as text alone: the join-time partial, the
          # deltas, a reset marker — the frames `follow` prints between its
          # lines, without the lines.
          def print_side_reply(cli, side_id)
            cli.core.loop_events(side_id) do |type, payload|
              case type
              when "snapshot" then cli.out.partial(payload["text"], length: payload["text_length"])
              when "text_delta" then cli.out.text(payload["text"].to_s)
              when "stream_reset" then cli.out.reset
              else nil
              end
            end
            # A bare line break, not a structured line: the answer ends
            # where the model's last word does.
            cli.out.write("\n") if cli.out.mid_line?
          end

          # 10 is the widest state word (`processed`, `steering`).
          def list_inputs(cli, public_id)
            rows = cli.core.inputs(public_id)
            cli.out.puts "(the queue is empty)" if rows.empty?
            rows.each { |row| cli.out.puts input_line(cli, row) }
            rows
          end

          def input_line(cli, row)
            line = "  #{row.fetch("state").ljust(10)} #{row.fetch("public_id")}  #{row.fetch("kind")}"
            line += %(  "#{row["text"]}") if row["text"]
            # The pictures the row carries, as the kernel describes them.
            pictures = Array(row["attachments"])
            line += "  attachments: #{pictures.map { |upload| cli.attachment_line(upload) }.join(", ")}" if pictures.any?
            line += "  (#{row["blocked_reason"]})" if row["blocked_reason"]
            # NOT BEFORE this time, as the kernel holds it.
            line += "  at #{row["deliver_at"]}" if row["deliver_at"]
            # The source kind, shown when it is not a person's own word.
            line += "  [#{row["origin"]}]" unless row["origin"] == "person"
            line
          end

          # ONE OF THE THREE: `--at`/`--in` are the kernel's
          # two fields through the one resolution `say` uses (a naive
          # `--at` in this terminal's zone); `--now` is the typed clear.
          def edit_schedule(options)
            named = [options[:at], options[:in], (true if options[:now] == true)].compact
            raise Rho::Error, "inputs edit takes one of --at TIME, --in DURATION or --now" if named.length > 1
            return { "deliver_in" => "0s" } if options[:now] == true

            Rho::Core.schedule_fields(deliver_at: options[:at], deliver_in: options[:in])
          end

          def remove_input(cli, public_id, input_public_id)
            document = cli.core.delete_input(public_id, input_public_id)
            cli.out.puts "removed:   #{document.dig("deleted", "public_id")}"
            document.fetch("deleted")
          end

          def edit_input(cli, public_id, input_public_id, text, schedule = {})
            row = cli.core.update_input(public_id, input_public_id, text: text, schedule: schedule)
            cli.out.puts "edited:    #{row.fetch("public_id")} (#{cli.input_state(row)})"
            row
          end

          # The one re-cut a verb names, as the daemon's route reads it:
          # `add` needs the principal and a level, `rm` the principal,
          # `default` a level; any other word is refused before the wire.
          # The principal is `@handle` or a public id,
          # relayed as typed — the daemon spells it for the kernel.
          def access_change(verb, rest)
            raise Rho::Error, "conversation participants takes add, rm or default: #{ACCESS_USAGE}" unless
              ACCESS_VERBS.include?(verb)

            principal, level = verb == "default" ? [nil, rest.first] : rest
            if verb != "default" && principal.to_s.empty?
              raise Rho::Error, "conversation participants #{verb} needs PRINCIPAL — a peer's @handle or public id " \
                "(this listing, `rho status`, or the workspace's principals)"
            end
            if verb != "rm" && level.to_s.empty?
              raise Rho::Error, "conversation participants #{verb} needs LEVEL: full, read or none"
            end

            { "op" => verb, "principal" => principal, "level" => level }.compact
          end

          def print_access(cli, access)
            cli.out.puts "default:   #{access.fetch("default")}"
            rows = Array(access["entries"])
            cli.out.puts "(no named participants)" if rows.empty?
            rows.each do |row|
              cli.out.puts "  #{row.fetch("level").ljust(5)} @#{row.fetch("handle")}  #{row.fetch("user_public_id")}  " \
                "#{row.fetch("kind")}  #{row["display_name"]}"
            end
            access
          end

          # The deck's listing: one line per live candidate, the active one
          # starred, so a person can name one to `--conceal`.
          def variant_deck(cli, public_id, turn)
            rows = cli.core.variants(public_id, turn)
            cli.out.puts "(this turn holds no live candidate)" if rows.empty?
            rows.each do |row|
              mark = row["active"] ? "*" : " "
              preview = row["content_preview"].to_s.empty? ? "" : "  #{row["content_preview"]}"
              cli.out.puts "#{mark} #{row.fetch("public_id")}  #{row["source"]}  #{row["status"]}#{preview}"
            end
            { "variants" => rows }
          end

          # The world outcome line, shared by `rewind` and `regenerate`.
          def world_line(world)
            case world.fetch("status")
            when "restored"
              undo = world["undo"] ? " (undo #{world["undo"]})" : ""
              # What the restore could not reach, present-only.
              marks = { "outside the root" => Array(world["outside"]), "ignored" => Array(world["ignored"]) }
                .reject { |_, paths| paths.empty? }.map { |label, paths| " [#{label}: #{paths.join(", ")}]" }
              "restored #{world.fetch("checkpoint")}#{undo}#{marks.join}"
            when "untouched" then "untouched"
            when "kept" then "kept"
            when "unavailable"
              reason = world.fetch("reason")
              reason == "no_checkpoint" && world["skipped"] ? "unavailable: no_checkpoint (skipped: #{world["skipped"]})" :
                "unavailable: #{reason}"
            when "failed"
              "failed: #{world["reason"]}#{world["undo"] ? " (undo #{world["undo"]})" : ""}"
            else world.fetch("status")
            end
          end
      end
    end
  end
end
