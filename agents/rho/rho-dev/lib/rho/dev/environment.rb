module Rho
  module Dev
    # THE CONVERSATION'S ENVIRONMENT FROM A TERMINAL: `environment ID [DIR] [--also D]… [--mcp
    # FILE.json] [--clear]` reads the record or binds a root set — a field
    # the verb did not name is KEPT (not sent), `--clear` is the typed null
    # — and hands the editor's MCP servers to the conversation through the
    # door's `mcp:` member (the file holds the ACP
    # `mcpServers` array exactly as a `session/new` would carry it; the
    # literal `[]` closes the set); `environments` lists the live table,
    # and `port ID --endpoint U --token T [--read] [--write]` registers the
    # editor's file-system port through the door's `fs:` member (`--clear`
    # drops it): the debugging spelling of what the ACP surface does at
    # `session/new`. rho's own `env` stays the daemon default's chip; these
    # are this gem's nouns, each one core primitive and its lines.
    module Environment
      ALSO_DESC = "Add a directory to the root set (repeatable); `--also` alone keeps the root and " \
                  "replaces the rest of the set".freeze
      MCP_DESC = "Hand the editor's MCP servers to the conversation: FILE.json holds the ACP `mcpServers` array " \
                 "(stdio `{name, command, args, env}`, http `{type, name, url, headers}`); the literal `[]` closes them".freeze
      # The one spelling that closes the conversation's servers.
      MCP_CLOSE = "[]".freeze
      # What the port's client is called when a terminal registers one.
      DEFAULT_CLIENT = "rho-dev".freeze

      def self.register(api)
        api.register_command("environment", usage: "environment ID [DIR]",
          description: "Show a followed conversation's environment record — its root set, anchor, source and the " \
                       "editor's MCP servers — or bind it: DIR sets the root, --also the rest of the set, " \
                       "--mcp the servers, --clear removes the record",
          options: {
            also: { type: :array, desc: ALSO_DESC },
            mcp: { type: :string, desc: MCP_DESC },
            clear: { type: :boolean, default: false, desc: "Remove the record: the conversation falls to the daemon's default root" },
          }, &method(:environment))
        api.register_command("environments",
          description: "List every followed conversation's environment record as the daemon holds it now",
          &method(:environments))
        api.register_command("port", usage: "port ID",
          description: "Register a file-system port on a followed conversation — a loopback http URL and its bearer, " \
                       "the flags the client advertised — so read, edit and write reach the editor's buffers; " \
                       "--clear drops it",
          options: {
            endpoint: { type: :string, desc: "The surface's loopback http URL (POST /fs/read, POST /fs/write)" },
            token: { type: :string, desc: "The bearer the surface checks; sent on every request, never printed" },
            read: { type: :boolean, default: false, desc: "The client advertised readTextFile: read goes through the port" },
            write: { type: :boolean, default: false, desc: "The client advertised writeTextFile: write goes through the port" },
            client: { type: :string, desc: "The client's name, as results and the lead say it (default #{DEFAULT_CLIENT})" },
            clear: { type: :boolean, default: false, desc: "Drop the conversation's port" },
          }, &method(:port))
      end

      class << self
        def environment(cli, (public_id, directory), options)
          raise Rho::Error, "environment needs a conversation ID" if public_id.to_s.empty?

          cli = Rho::Dev.terminal(cli)
          fields = bind_fields(directory, options)
          document =
            if options[:clear]
              cli.core.bind_environment(public_id, root: nil)
            elsif fields.empty?
              cli.core.conversation_environment(public_id)
            else
              cli.core.bind_environment(public_id, **fields)
            end
          report(cli, public_id, document)
        end

        # The door's members the verb names, each only when it was named:
        # the root, the rest of the set, the editor's servers.
        def bind_fields(directory, options)
          fields = {}
          fields[:root] = File.expand_path(directory) unless directory.nil?
          fields[:directories] = Array(options[:also]).map { |path| File.expand_path(path) } unless options[:also].nil?
          fields[:mcp] = mcp_entries(options[:mcp]) unless options[:mcp].nil?
          fields
        end

        # THE SERVERS' FILE: the ACP `mcpServers` array, read whole
        # and sent as the door received it — the daemon's registrar judges
        # each entry (a malformed one is its 400); here only the file and
        # its outer shape are the verb's to refuse. `[]` closes the set
        # without a file.
        def mcp_entries(spelling)
          return [] if spelling.strip == MCP_CLOSE

          path = File.expand_path(spelling)
          raise Rho::Error, "--mcp #{spelling}: no such file — name a JSON file holding the ACP mcpServers array, or `[]` to close" unless File.file?(path)

          entries = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
          raise Rho::Error, "--mcp #{spelling}: the file must hold a JSON array of mcpServers entries, got #{entries.class.name.downcase}" unless entries.is_a?(Array)

          entries
        rescue JSON::ParserError => error
          raise Rho::Error, "--mcp #{spelling}: not JSON — #{error.message}"
        end

        def port(cli, (public_id), options)
          raise Rho::Error, "port needs a conversation ID" if public_id.to_s.empty?

          cli = Rho::Dev.terminal(cli)
          document =
            if options[:clear]
              cli.core.bind_environment(public_id, fs: nil)
            else
              raise Rho::Error, "port needs --endpoint and --token (or --clear)" if options[:endpoint].to_s.empty? || options[:token].to_s.empty?

              cli.core.bind_environment(public_id, fs: {
                url: options[:endpoint], token: options[:token], read: options[:read] == true, write: options[:write] == true,
                client: options[:client].to_s.empty? ? DEFAULT_CLIENT : options[:client],
              })
            end
          report(cli, public_id, document)
        end

        def environments(cli, _args, _options)
          cli = Rho::Dev.terminal(cli)
          rows = cli.core.environments
          if rows.empty?
            cli.out.puts "environments: none — no followed conversation has a record"
            return rows
          end

          rows.each do |row|
            cli.out.puts row_line(row)
            mcp_lines(row["mcp"]).each { |line| cli.out.puts line }
          end
          rows
        end

        # ONE LINE PER SERVER the editor handed the conversation:
        # the name, its state, and a down row's fault after the dash —
        # `rho mcp`'s `down:` sentence, in the record's own column. No
        # servers, no lines: the set closed by `--mcp []` prints nothing.
        def mcp_lines(rows)
          Array(rows).map do |row|
            words = "mcp:          #{row["name"]}  #{row["state"]}"
            row["fault"] ? "#{words} — #{row["fault"]}" : words
          end
        end

        # ONE LINE for a root set: the root, then the rest in parentheses.
        def root_set(root, directories)
          rest = Array(directories)
          rest.empty? ? root.to_s : "#{root} (+ #{rest.join(", ")})"
        end

        # The relay's line: the runner, its state, the runner's boot when it
        # answered, and whether the root is on that host.
        def relayed_line(relayed)
          return nil if relayed.nil?

          words = ["#{relayed["runner"]} #{relayed["state"]}"]
          facts = []
          facts << "booted #{relayed["booted_at"]}" if relayed["booted_at"]
          facts << "the root is not on that host" if relayed["resolved"] == false
          words << "(#{facts.join("; ")})" unless facts.empty?
          words.join(" ")
        end

        # The port's words: `on — <client> (read, write)`, or `off`.
        def fs_words(fs)
          return "off" if fs.nil?

          flags = %w[read write].select { |flag| fs[flag] }
          "on — #{fs["client"]} (#{flags.join(", ")})"
        end

        private

          # The record's lines, in `do`'s own column.
          def report(cli, public_id, document)
            cli.out.puts "conversation: #{public_id}"
            cli.out.puts "root:         #{document["root"]}"
            directories = Array(document["directories"])
            cli.out.puts "directories:  #{directories.empty? ? "none" : directories.join(", ")}"
            cli.out.puts "anchor:       #{document["anchor"]}" if document["anchor"]
            cli.out.puts "source:       #{source_words(document)}"
            cli.out.puts "resolved:     #{resolved_word(document["resolved"])}"
            line = relayed_line(document["relayed"])
            cli.out.puts "relayed:      #{line}" if line
            cli.out.puts "fs:           #{fs_words(document["fs"])}"
            mcp_lines(document["mcp"]).each { |line| cli.out.puts line }
            document
          end

          def source_words(document)
            source = document["source"]
            return "default (no record)" if source == "default"

            facts = []
            facts << "version #{document["lock_version"]}" unless document["lock_version"].nil?
            facts << "written #{document["updated_at"]}" if document["updated_at"]
            facts.empty? ? source.to_s : "#{source} (#{facts.join(", ")})"
          end

          def resolved_word(resolved)
            case resolved
            when true then "yes"
            when false then "no — not on this host; placement zero serves it here"
            when "refused" then "refused — under a protected root"
            else resolved.to_s
            end
          end

          def row_line(row)
            words = [row["conversation"], root_set(row["root"], row["directories"]), "anchor #{row["anchor"]}", row["source"]]
            words << "relayed #{row.dig("relayed", "runner")} #{row.dig("relayed", "state")}" if row["relayed"]
            fs = row["fs"]
            words << (fs ? "fs on (#{%w[read write].select { |flag| fs[flag] }.join(", ")}) #{fs["client"]}" : "fs off")
            words.join("  ")
          end
      end
    end
  end
end
