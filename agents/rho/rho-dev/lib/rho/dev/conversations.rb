require "json"

module Rho
  module Dev
    # THE CONVERSATION-GRAIN VERBS: a repair now (`compact`), the question
    # beside the work (`side`), the queue (`inputs`), who may see it
    # (`conversation participants`), the branch and the redo (`rewind`,
    # `regenerate`), the deck (`variant`), the mainline (`turns`).
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
          description: "Compact a run or conversation this daemon follows: a conversation's running reply is " \
                       "repaired on its next round (idle, its history is summarized); a run needs the round's key",
          &method(:compact))
        api.register_command("side", usage: "side [ID]",
          description: "Open (or resume) the side conversation of a conversation this daemon follows, read-write tools by default; " \
                       "then `rho say <side-id>`",
          options: { tools: { type: :string, enum: %w[read write],
                              desc: "Tool access: write (default) or read-only; applies to subsequent side turns" } },
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
        # through the daemon; `--keep-checkpoints` forks (or regenerates) without
        # putting the files back.
        api.register_command("rewind", usage: "rewind CONVERSATION_ID TURN",
          description: "Branch a conversation at a turn and put the files back to that point: fork, then restore " \
                       "each checkpoint through its original Runner (--keep-checkpoints forks alone); TURN is a turn id " \
                       "or a bare position",
          options: {
            "keep-checkpoints": { type: :boolean, default: false, desc: "Fork without restoring checkpoints" },
            title: { type: :string, desc: "A title for the child conversation" },
          }, &method(:rewind))
        api.register_command("regenerate", usage: "regenerate CONVERSATION_ID TURN",
          description: "Regenerate a run-backed turn's reply after restoring each changed Runner environment so the model " \
                       "re-does the work (--keep-checkpoints keeps the current environments); TURN " \
                       "is the tail turn's id or position",
          options: {
            "keep-checkpoints": { type: :boolean, default: false, desc: "Regenerate without restoring checkpoints" },
            model: { type: :string, desc: "provider/reference for the new candidate (default: the turn's own)" },
            "idempotency-key": { type: :string, desc: "Reuse a printed key to recover the same regeneration" },
          }, &method(:regenerate))
        # THE DECK FROM A TERMINAL (CLI alongside the capability): a turn's candidates, and the kernel's view-state door
        # on one of them — conceal a sample, restore it.
        # THE REPLAY'S MAINLINE FROM A TERMINAL: what `session/load` reads, printed.
        api.register_command("turns", usage: "turns CONVERSATION_ID",
          description: "A conversation's turns in position order (the replay's mainline): the position, the id, the " \
                       "role, the kind, the status, the backing run and the words; the daemon pages the kernel's " \
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
        # history when idle; a standalone run compacts ONE named round (the
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

        # The Core owns the default tool posture. An explicit choice persists
        # on the side for subsequent `rho say` turns.
        def side(cli, (public_id), options)
          answer = cli.core.open_side(parent: public_id, **(options[:tools] ? { tools: options[:tools] } : {}))
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

          rewind = cli.core.rewind(public_id, turn, keep_checkpoints: options[:"keep-checkpoints"] == true, title: options[:title])
          restoration = rewind.fetch("restoration")
          cli.out.puts "conversation: #{rewind.fetch("conversation")}"
          position = rewind["position"] ? " (position #{rewind["position"]})" : ""
          cli.out.puts "forked_from:  #{rewind.fetch("forked_from")}#{position}"
          report_restoration(cli, restoration)
          raise Rho::Error, "Runner checkpoints could not be fully restored" if %w[failed partial unavailable].include?(restoration.fetch("status"))

          rewind
        end

        # REGENERATE: re-do a run-backed tail turn's reply,
        # restoring the world it changed first. Prints the turn, the new
        # candidate and what the restore did; a door that refused AFTER
        # the restore prints the undo and exits non-zero.
        def regenerate(cli, (public_id, turn), options)
          raise Rho::Error, "regenerate needs CONVERSATION_ID and TURN" if public_id.to_s.empty? || turn.to_s.empty?

          key = options[:"idempotency-key"] || SecureRandom.uuid
          cli.out.puts "idempotency-key: #{key}"
          regenerate = cli.core.regenerate(public_id, turn, idempotency_key: key, keep_checkpoints: options[:"keep-checkpoints"] == true,
            model: options[:model])
          restoration = regenerate.fetch("restoration")
          cli.out.puts "turn:      #{regenerate.fetch("turn")}"
          cli.out.puts "variant:   #{regenerate["variant"]}" if regenerate["variant"]
          report_restoration(cli, restoration)
          if restoration["door_refused"]
            raise Rho::Error, "Runner checkpoints were restored but the door refused: #{restoration["door_refused"]}"
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
          # the kind, the status, the backing run when the reply minted
          # one, and the WORDS WHOLE, folded onto the line (this is the replay's mainline, and a width that cut the words hid the ones a reader looks for; `--json` is the document itself).
          def turn_line(cli, turn)
            variant = turn["active_variant"] || {}
            parts = [turn.fetch("position").to_s.rjust(4), turn.fetch("public_id"), turn.fetch("role"), turn.fetch("kind"),
                     turn.fetch("status")]
            parts << "run #{variant["run_public_id"]}" if variant["run_public_id"]
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

          def report_restoration(cli, restoration)
            status = restoration.fetch("status")
            reason = restoration["reason"] ? ": #{restoration["reason"]}" : ""
            cli.out.puts "restoration:  #{status}#{reason}"
            restoration.fetch("runners").each do |runner|
              cli.out.puts "runner:       #{runner.fetch("runner_executor_public_id")} #{restoration_line(runner)}"
            end
          end

          def restoration_line(runner)
            line = runner.fetch("status")
            line += " #{runner["checkpoint"]}" if runner.key?("checkpoint")
            line += ": #{runner["reason"]}" if runner["reason"]
            line += " (undo #{runner["undo"]})" if runner["undo"]
            line += " (skipped: #{runner["skipped"]})" if runner["skipped"]
            { "outside the root" => Array(runner["outside"]), "ignored" => Array(runner["ignored"]) }.each do |label, paths|
              line += " [#{label}: #{paths.join(", ")}]" unless paths.empty?
            end
            line
          end
      end
    end
  end
end
