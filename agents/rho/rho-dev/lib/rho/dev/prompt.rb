require "json"

module Rho
  module Dev
    # THE PROMPT FAMILY: the preview is the estimate rendered
    # through the kernel's one door — CLI alongside the capability, so an
    # order can be read before a UI exists; `show` is rho's own slots.
    module Prompt
      PROMPT_USAGE = "`rho prompt preview CONVERSATION_ID [--model M] [--prompt TEXT] [--to IDENT] " \
                     "[--template FILE] [--var name=value]… [--json]` or `rho prompt show [SLOT]`".freeze
      BLOCK_COLUMNS = %w[# block type role state tokens allocated].freeze

      def self.register(api)
        api.register_command("prompt",
          usage: "prompt preview CONVERSATION_ID | prompt show [SLOT]",
          description: "preview: the bytes a send of these words would seal — the block evidence, the storage " \
                       "line, then the entries as JSON — under the addressee --to names (@handle or id; default " \
                       "the conversation's answerer), the turn's --var name=value words and a trial --template " \
                       "file (never stored); show: this profile's own prompt documents, or one slot whole",
          options: {
            model: { type: :string, desc: "provider/reference (default: the model `rho say` sends on — the " \
                                          "conversation's own, then the daemon's `default_model` setting)" },
            prompt: { type: :string, desc: "The words the preview models as the turn's input" },
            to: { type: :string, desc: "Whose declaration and template to compile under: @handle or a public id" },
            template: { type: :string, desc: "A JSON file holding a trial template (- for stdin); estimate-only" },
            var: { type: :array, desc: "name=value words for the declared template variables, several after " \
                                       "the one flag (`--var scene=night mood=calm`)" },
            json: { type: :boolean, default: false, desc: "Print the whole preview document as JSON" },
          },
          &method(:prompt))
      end

      class << self
        # `preview` is the estimate rendered — what a send of these words
        # would seal, under the addressee named — printed as a person
        # reads it (the mechanism, the count, history, the storage line,
        # one row per block) and then the entries as pretty JSON, exactly
        # as `request` prints a sealed one; `show` is rho's own slots. No
        # `write`/`delete`: rho rewrites its `system_prompt` from the
        # guideline at every declare edge, so a person's write would be
        # reverted at the next boot; the other slots are other anchors'.
        def prompt(cli, (verb, *rest), options)
          case verb
          when "preview" then preview_prompt(cli, rest.first, options)
          when "show" then show_prompt(cli, rest.first)
          else raise Rho::Error, "prompt takes preview or show: #{PROMPT_USAGE}"
          end
        end

        private

          def preview_prompt(cli, public_id, options)
            raise Rho::Error, "prompt preview needs CONVERSATION_ID — the conversation `rho do` printed" if
              public_id.to_s.empty?

            template = options[:template].to_s.empty? ? nil : template_file(options[:template])
            preview = cli.core.prompt_preview(public_id, model: options[:model], prompt: options[:prompt],
              to: options[:to], variables: variable_pairs(options[:var]), template: template)
            options[:json] ? cli.out.puts(JSON.pretty_generate(preview)) : print_preview(cli, preview)
            preview
          end

          # `--var name=value…` (one flag, several words), each split at
          # the FIRST `=`: a value may carry one.
          def variable_pairs(pairs)
            Array(pairs).to_h do |pair|
              name, separator, value = pair.to_s.partition("=")
              raise Rho::Error, "--var takes name=value, got #{pair.inspect}" if name.empty? || separator.empty?

              [name, value]
            end
          end

          # A trial template from a file, as the kernel's door reads it —
          # the grammar is the kernel's, judged there and relayed by path.
          def template_file(path)
            template = JSON.parse(path == "-" ? $stdin.read : File.read(path, encoding: "UTF-8"))
            raise Rho::Error, "the template in #{path} must be a JSON object" unless template.is_a?(Hash)

            template
          rescue JSON::ParserError, SystemCallError => error
            raise Rho::Error, "cannot read a template from #{path}: #{error.message}"
          end

          def print_preview(cli, preview)
            cli.out.puts "mechanism: #{preview.fetch("mechanism")}"
            cli.out.puts "tokens:    #{preview.fetch("input_tokens")} (#{preview["tokenizer_exact"] ? "exact" : "estimated"})  " \
              "limit #{preview["catalog_input_token_limit"] || "-"}  advisory #{preview["advisory_input_token_limit"] || "-"}"
            cli.out.puts "history:   #{history_words(preview.fetch("history"))}"
            cli.out.puts "storage:   #{storage_words(preview.fetch("storage"))}"
            cli.out.puts "blocks:"
            print_blocks(cli, preview.fetch("blocks"))
            memory = preview.fetch("memory")
            cli.out.puts "memory:    #{memory.fetch("included")} included, #{memory.fetch("omitted")} omitted"
            slots = preview.fetch("slots")
            cli.out.puts "slots:     #{slots.empty? ? "(none registered)" : slots.map { |slot, version| "#{slot} v#{version}" }.join("  ")}"
            cli.out.puts
            cli.out.puts "entries:"
            cli.out.puts JSON.pretty_generate(preview.fetch("entries"))
          end

          def history_words(history)
            words = ["selected #{history.fetch("selected")}"]
            skipped = "skipped #{history.fetch("skipped")}"
            skipped += " (#{history["skipped_reason"]})" if history["skipped_reason"]
            words << skipped
            words << "compacted #{history["compacted"]}" if history["compacted"].to_i.positive?
            words.join("  ")
          end

          # Over the seal's bound the line names the refusal beside the
          # number: showing the overflow is what a preview is for.
          def storage_words(storage)
            verdict = storage.fetch("within_bound") ? "within bound" : "over: #{storage.fetch("refusal")}"
            "#{storage.fetch("bytes")} of #{storage.fetch("bound")} bytes (#{verdict})"
          end

          # One row per block in the template's order, the dash for what
          # is absent (a role-less block; no grant on a windowless model).
          def print_blocks(cli, blocks)
            rows = blocks.map do |row|
              [row.fetch("index"), row.fetch("block"), row.fetch("type"), row["role"] || "-", row.fetch("state"),
               row.fetch("tokens"), row["allocated_tokens"] || "-"].map(&:to_s)
            end
            widths = ([BLOCK_COLUMNS] + rows).transpose.map { |column| column.map(&:length).max }
            ([BLOCK_COLUMNS] + rows).each do |cells|
              line = cells.each_with_index.map do |cell, index|
                index >= 5 ? cell.rjust(widths[index]) : cell.ljust(widths[index])
              end
              cli.out.puts "  #{line.join("  ").rstrip}"
            end
          end

          def show_prompt(cli, slot)
            document = cli.core.prompt_documents(slot: slot)
            if slot.to_s.empty?
              rows = document.fetch("prompt_documents")
              cli.out.puts "(no prompt documents on this profile)" if rows.empty?
              rows.each do |row|
                cli.out.puts "#{row.fetch("slot")}  #{row.fetch("role")}  v#{row.fetch("version")}  " \
                  "#{row.fetch("bytesize")} bytes  #{row.fetch("written_at")}"
              end
              rows
            else
              row = document.fetch("prompt_document")
              cli.out.puts row.fetch("content")
              row
            end
          end
      end
    end
  end
end
