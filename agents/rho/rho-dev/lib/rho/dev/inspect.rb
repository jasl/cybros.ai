require "json"

module Rho
  module Dev
    # THE READS OF THE MACHINERY: the thread, the picture, the bytes a
    # round was sent, an upload's bytes, the provider lanes.
    module Inspect
      # A turn id is UUID-shaped; a task key (`r1`, `r1t0`, an authored
      # word) never is — the second argument's shape picks the reading.
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      def self.register(api)
        api.register_command("providers",
          description: "The account's provider lanes, with each lane's unavailable_until when a floor stands",
          &method(:providers))
        api.register_command("transcript", usage: "transcript RUN_ID",
          description: "The thread: the mainline's rounds, the calls each one read, the branches under them " \
                       "(--follow keeps reading the mainline as it settles)",
          options: {
            limit: { type: :numeric, desc: "How many rounds (newest first from the kernel)" },
            before: { type: :string, desc: "The cursor a previous page answered" },
            prefix: { type: :string, desc: "A call key: print the branch under it instead of the mainline (a page, never followed)" },
            follow: { type: :boolean, default: false,
                      desc: "After the page, fold the daemon's stream: a mainline round printed as it settles, " \
                            "the live line as it moves; ends with the run (Ctrl-C to stop)" },
            timeout: { type: :numeric, desc: "With --follow, give up after this many seconds" },
          }, &method(:transcript))
        # THE CAPTURE'S BYTES: a `resource_link` on a task read
        # names an upload; this is the one read of it from a terminal —
        # whole, to stdout, redirect it. A debug verb: no --out, no Range.
        # `--thumbnail` / `--preview` print the kernel's named
        # representation of it instead — the same whole output.
        api.register_command("fetch", usage: "fetch UPLOAD_ID",
          description: "An upload's bytes, whole, to stdout: a capture a task's resource_link named, or an " \
                       "attachment this daemon may read (redirect it to a file); --thumbnail or --preview " \
                       "prints the kernel's named representation of it instead (a PNG for a picture, a PDF's " \
                       "page or a video's frame; an upload with none is the kernel's representation_unavailable)",
          options: {
            thumbnail: { type: :boolean, default: false, desc: "The thumbnail (256 px on the longest edge) instead of the bytes" },
            preview: { type: :boolean, default: false, desc: "The preview (1600 px on the longest edge) instead of the bytes" },
          }, &method(:fetch))
        api.register_command("graph", usage: "graph RUN_ID",
          description: "The whole run as a Mermaid flowchart (--json for the nodes and edges)",
          options: { json: { type: :boolean, default: false, desc: "Print the nodes, edges and text as JSON" } },
          &method(:graph))
        api.register_command("request", usage: "request RUN_ID TASK_KEY | request CONVERSATION_ID TURN_ID",
          description: "The bytes a round or a turn was sent: the sealed entries and the request options, as JSON",
          &method(:request))
      end

      class << self
        # `rho providers` (the provider admission floor): the
        # account's lanes through the daemon. One line per lane, the
        # `unavailable_until` as the kernel sent it, `—` when null.
        def providers(cli, _args, _options)
          rows = cli.core.providers
          cli.out.puts "(this server serves no provider lanes)" if rows.empty?
          rows.each { |row| cli.out.puts provider_line(row) }
          rows
        end

        # THE THREAD: the mainline newest-first from the kernel,
        # printed in reading order; `--prefix CALL` prints the branch
        # under that call instead — a page, never followed; `--follow`
        # keeps reading the MAINLINE after the page (W-s5: a branch round's
        # key is run-global and places nowhere live), so the two flags
        # together are a refusal, not a guess.
        def transcript(cli, (public_id), options)
          if options[:follow] && !options[:prefix].nil?
            raise Rho::Error, "--follow follows the mainline and --prefix is a page (a branch is never followed): drop one"
          end

          body = cli.core.transcript(public_id, limit: options[:limit], before: options[:before], prefix: options[:prefix])
          rounds = Array(body["rounds"])
          if rounds.empty?
            cli.out.puts(options[:prefix].nil? ? "(no rounds yet)" : "(nothing under #{options[:prefix]})")
          end
          rounds.each { |round| report_round(cli, round) }
          cli.out.puts "older:     #{body["next_before"]}" if body["has_older"]
          return body unless options[:follow]

          follow_thread(cli, public_id, body, deadline: options[:timeout])
        end

        # The bytes a `resource_link` named, whole, to stdout:
        # the daemon fetches them on the member plane; a person redirects.
        def fetch(cli, (public_id), options)
          raise Rho::Error, "fetch needs UPLOAD_ID" if public_id.to_s.empty?
          raise Rho::Error, "fetch takes --thumbnail or --preview, not both" if options[:thumbnail] && options[:preview]

          kind = options[:thumbnail] ? "thumbnail" : (options[:preview] ? "preview" : "bytes")
          bytes = cli.core.upload_bytes(public_id, kind: kind)
          cli.out.write(bytes)
          cli.out.flush
          bytes.bytesize
        end

        # The picture: Mermaid by default — the text a person pastes into a
        # renderer — and the nodes and edges behind it with `--json`.
        def graph(cli, (public_id), options)
          picture = cli.core.graph(public_id)
          cli.out.puts(options[:json] ? JSON.pretty_generate(picture) : picture.fetch("mermaid"))
          picture
        end

        # THE BYTES A ROUND OR A TURN WAS SENT: the request
        # options, then the entries, each as pretty JSON — a debug verb's
        # whole value is the bytes, and a line-per-entry rendering would
        # hide them.
        def request(cli, (public_id, second), _options)
          if second.to_s.empty?
            raise Rho::Error, "request needs a RUN_ID and a TASK_KEY, or a CONVERSATION_ID and a TURN_ID"
          end

          selector = second.match?(UUID) ? "turn" : "task_key"
          sealed = cli.core.request_bytes(public_id, selector, second)
          cli.out.puts "request_options:"
          cli.out.puts JSON.pretty_generate(sealed.fetch("request_options"))
          cli.out.puts
          cli.out.puts "entries:"
          cli.out.puts JSON.pretty_generate(sealed.fetch("entries"))
          sealed
        end

        private

          def provider_line(row)
            [
              row.fetch("id"), row.fetch("credentials"),
              row.fetch("enabled") ? "enabled" : "disabled",
              row.fetch("configured") ? "configured" : "unconfigured",
              "#{row.fetch("models")} models",
              row["unavailable_until"] ? "unavailable until #{row["unavailable_until"]}" : "—",
            ].join("  ")
          end

          # THE FOLD: the page seeds the SDK's
          # `ThreadAccumulator`, then the daemon's stream — the settled
          # `round`/`call` items the follower relays whole, the kernel's
          # frames off the ring — is folded through it: a mainline round
          # prints when it SETTLES (the row the kernel published, whole),
          # the `live` line whenever what is running changes, and the
          # stream's own end closes it. The accumulator applies the mainline
          # law; this reads types and calls methods, as the README shows.
          # Only this run's items count: a conversation host relays every
          # turn's run, and a frame naming another is not this thread's.
          def follow_thread(cli, public_id, page, deadline:)
            thread = CybrosAgent::Api::ThreadAccumulator.new
            thread.seed(page)
            live = thread.live
            cli.core.follower_events(public_id, deadline: deadline) do |type, payload|
              if type == "closed"
                cli.out.puts "(stream ended: #{payload["reason"]})"
                next
              end
              next unless payload["run_public_id"].nil? || payload["run_public_id"] == public_id

              row = fold_frame(thread, type, payload)
              report_round(cli, row) if row && type == "round"
              now = thread.live
              next if now == live

              live = now
              cli.out.puts "live:      #{live.empty? ? "(nothing)" : live.join(", ")}"
            end
            thread.snapshot
          end

          # One frame off the daemon's stream to the accumulator's one
          # method for it; a type this CLI predates folds nothing.
          def fold_frame(thread, type, payload)
            case type
            when "round" then thread.settle_round(payload)
            when "call" then thread.settle_call(payload)
            when "progress"
              case payload["type"]
              when "round_started" then thread.round_started(payload)
              when "step_started" then thread.step_started(payload)
              when "step_claimed" then thread.step_claimed(payload)
              else nil
              end
            else nil
            end
          end

          # A round in reading order: the header, the calls it READ above
          # its own words (they happened first), the count it withheld,
          # the branches a person can expand with `--prefix`, then the text.
          # A branch's row (an expansion's) says so after its key.
          def report_round(cli, round)
            usage = round["usage"]
            fan = round["calls"] || {}
            items = Array(fan["items"])
            count = fan["count"].to_i
            head = "#{round.fetch("task_key")}#{" (branch)" if round["mainline"] == false}  #{round.fetch("status")}"
            head += "  #{count} call#{"s" unless count == 1}" if count.positive?
            head += "  #{usage["total_tokens"]}t" if usage && usage["total_tokens"]
            cli.out.puts head
            items.each do |call|
              mark = call["is_error"] ? "!" : "-"
              cli.out.puts "  #{mark} #{call.fetch("name")} #{call.fetch("status")}#{" — #{call["title"]}" if call["title"]}"
              cli.out.puts "    #{call["output_preview"]}" if call["output_preview"]
            end
            overflow = count - items.length
            cli.out.puts "  … #{overflow} more calls" if overflow.positive?
            branches = Array(round["branches"])
            cli.out.puts "  +#{branches.length} branch#{"es" unless branches.length == 1} under #{branches.join(", ")}" if branches.any?
            cli.out.puts "  #{round["text_preview"]}" if round["text_preview"]
            cli.out.puts "  ! #{round.dig("error", "key")}" if round["error"]
          end
      end
    end
  end
end
