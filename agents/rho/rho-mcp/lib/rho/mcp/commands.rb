require "json"
require "time"

module Rho
  module Mcp
    # THE CLI: `rho mcp` reads the daemon's `GET /mcp`
    # and prints one block per server — the connection, the tools with
    # their lowered bytes (the invoice the model pays on every cached
    # prefix), the skips with their reasons, the env/header NAMES with every
    # value masked; `rho mcp probe NAME` connects from the CLI process
    # against the settings file's row (the daemon connected nothing here:
    # `serving_tools: false`) — in its own group, torn down in an `ensure`
    # — and prints what the model WOULD read, honestly: every non-printable
    # byte escaped, the byte count beside each description, the schema
    # constructs a provider may refuse flagged. No `rho mcp sync`: a
    # re-list is the next boot.
    #
    # THE OAUTH VERBS: `rho mcp login
    # NAME [--no-browser]` (the authorization URL always printed, then the
    # browser tried; a server that answers anonymously but publishes an
    # authorization server is logged in to as well) and `rho mcp logout
    # NAME` run here too, against
    # the settings file's row as `probe` does; `rho mcp` prints each OAuth
    # row's `auth:` line — from the daemon's document, or with NO daemon
    # from the settings rows and the credential files alone (no network):
    # the one place a person checks logins before a boot. `rho doctor`
    # stays untouched: rho reads nothing inside `mcp_servers`.
    #
    # THE SWITCH (`rho mcp enable NAME` / `rho mcp disable NAME`): the person's file is the one place —
    # `mcp_servers.NAME.enabled`, the member a hand-written row carries too
    # — written through rho's one-key rewrite (`Home#write_setting`, the
    # door `rho runners use` takes) with the whole `mcp_servers` object
    # rebuilt around that one member. The shipped example (`Builtin`) gets
    # a partial row in the file that overlays it; a name neither built in
    # nor in the file is refused by name; a state already held writes
    # nothing. The daemon reads the table at boot, so the verb names the
    # restart. Every table these verbs read is the person's UNDER the
    # shipped row (`settings_table`); the write reads the person's alone.
    #
    # EVERY THIRD-PARTY BYTE these verbs print — a server's identity and
    # `down:` detail, an authorization server's issuer, scope, error and
    # description, the consent line, the URL a person copies — passes the
    # ONE escaper (`escape`), after the row's redaction where this process
    # holds the row's secrets (`escape(redact.call(…))`, the probe's
    # spelling); the daemon's document is its own redacted product and is
    # escaped as it stands. A hostile AS answering
    # `error_description=%1b]0;…%07` rewrites nothing on the terminal.
    module Commands
      USAGE = "mcp | mcp probe NAME | mcp enable NAME | mcp disable NAME | mcp login NAME [--no-browser] | mcp logout NAME".freeze
      DESCRIPTION = "List the MCP servers this daemon runs and their declaration bytes (the shipped example, context7, " \
                    "is listed disabled until `enable context7`); " \
                    "`probe NAME` connects from here and prints what a server would announce; " \
                    "`enable NAME` / `disable NAME` write the row's switch into settings.json (the daemon reads it at its " \
                    "next boot); " \
                    "`login NAME` authorizes rho with NAME's authorization server in your browser (the URL is printed " \
                    "first, and a server that answers anonymously but publishes an authorization server is logged in to too)".freeze
      OPTIONAL_WORD = "optional: the server answers anonymously too".freeze
      OPTIONS = { "no-browser": { type: :boolean, default: false,
                                  desc: "Never open a browser: the authorization URL is printed as always; paste the " \
                                        "redirected URL back on stdin" } }.freeze
      NO_DAEMON = "no daemon running — `rho mcp probe NAME` connects from here".freeze
      NO_HOME = "this host has no rho home to hold a login — declare the server on a rho home".freeze
      RISKY_SCHEMA_KEYS = %w[$ref $defs allOf anyOf oneOf].freeze
      # Zero-width and bidi characters read one way to a terminal and
      # another to a model; every C0/C1 control byte likewise.
      INVISIBLE = /[\u200B-\u200F\u2028-\u202E\u2060-\u2064\uFEFF\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/

      module_function

      def run(cli, args, options)
        case args
        in [] then list(cli)
        in ["probe", name] then probe(cli, name)
        in ["enable", name] then switch(cli, name, true)
        in ["disable", name] then switch(cli, name, false)
        in ["login", name] then login(cli, name, options)
        in ["logout", name] then logout(cli, name)
        else refuse("usage: rho #{USAGE}")
        end
      end

      # A one-sentence refusal the CLI prints (`Rho::Error` where rho is
      # loaded — the only process with these verbs; the gem's own root
      # otherwise, so nothing here names a constant rho-runner lacks).
      def refuse(sentence)
        raise (defined?(Rho::Error) ? Rho::Error : Rho::Mcp::Error), sentence
      end

      # ---- rho mcp ----

      def list(cli)
        daemon = cli.core.running_daemon
        if daemon.nil?
          cli.out.puts NO_DAEMON
          list_logins(cli)
          return nil
        end

        document = cli.core.parse(cli.core.get(daemon, "/mcp"))
        document.fetch("servers").each { |server| print_server(cli.out, server) }
        total = document.fetch("total")
        cli.out.puts "total:     #{total.fetch("tools")} tools announced, #{number(total.fetch("bytes"))} bytes; " \
                     "#{total.fetch("documents")} documents"
        document
      end

      # NO DAEMON: each OAuth row's `auth:` line from the settings and the
      # credential files alone; a disabled row names its switch.
      def list_logins(cli)
        rows(cli).each do |row|
          next unless row.oauth?

          word = row.enabled? ? "not connected from this process" : disabled_word(row.key)
          cli.out.puts "server:    #{row.key}  #{row.transport}  #{row.launch}  serves #{row.serves}  #{word}"
          storage = Oauth.storage_for(row, home: cli.home)
          auth = storage ? status_document(storage.status) : { "state" => "needs_login", "reason" => NO_HOME }
          cli.out.puts "  auth:    #{auth_line(auth, shown(Rho::Runner::Redact.new(row.secrets, live: storage)))}"
        end
      end

      def print_server(out, server)
        out.puts "server:    #{server_line(server, method(:escape))}"
        auth = server.fetch("auth")
        out.puts "  auth:    #{auth_line(auth, method(:escape))}" if auth.fetch("kind") == "oauth"
        return if %w[tools skipped documents skipped_documents].all? { |key| server.fetch(key).empty? }

        print_tools(out, server) unless server.fetch("tools").empty? && server.fetch("skipped").empty?
        print_documents(out, server)
        env = server.fetch("env")
        out.puts "  env:     #{env.map { |name| "#{name}=#{Rho::Runner::Redact::MASK}" }.join("  ")}" unless env.empty?
        headers = server.fetch("headers")
        out.puts "  headers: #{headers.map { |name| "#{name}: #{Rho::Runner::Redact::MASK}" }.join("  ")}" unless headers.empty?
      end

      # `shown` is what a third-party string looks like on the terminal. An
      # editor's row names its owner — the
      # conversation the daemon holds it for — after the address; a boot
      # row's line is byte for byte what it was.
      def server_line(server, shown)
        head = [server.fetch("key"), server["transport"], server["launch"],
                ("serves #{server["serves"]}" if server["serves"]),
                ("conversation #{shown.call(server["owner"])}" if server["owner"])].compact.join("  ")
        case server.fetch("state")
        when "connected"
          "#{head}  #{connected_word(server["pid"], server["pgid"])}  #{shown.call(server["protocol_version"])}  " \
            "#{identity_word(server["server_name"], server["server_version"], shown)}"
        when "unconnected" then "#{head}  not connected from this process"
        when "disabled" then "#{head}  #{disabled_word(server.fetch("key"))}"
        else "#{head}  down: #{shown.call(server["detail"])}"
        end
      end

      def disabled_word(key) = "disabled — `rho mcp enable #{key}`"

      def identity_word(name, version, shown)
        name ? "#{shown.call(name)} #{shown.call(version)}" : "(unnamed)"
      end

      # A stdio server is a child with a pid and a group; an http server
      # is a session with neither.
      def connected_word(pid, pgid)
        pid ? "connected (pid #{pid}, pgid #{pgid})" : "connected"
      end

      # The `auth:` line from the report's `auth` member: a state, a
      # reason, keys and a clock — never a value; the issuer, scope and
      # reason are the authorization server's bytes; the optional word is
      # the store's mark (the server answers anonymously too).
      def auth_line(auth, shown)
        case auth["state"]
        when "logged_in"
          issued = auth["issued_at"] ? "tokens issued #{clock_word(auth["issued_at"])}; " : ""
          optional = auth["optional"] ? "; #{OPTIONAL_WORD}" : ""
          "oauth — logged in (#{issued}issuer #{shown.call(auth["issuer"])}; scope #{shown.call(auth["scope"])}; " \
            "#{auth["refresh_token"] ? "refresh token held" : "no refresh token"}#{optional})"
        when "credential_file" then "oauth — #{shown.call(auth["reason"])}"
        else "oauth — needs login (#{shown.call(auth["reason"])})"
        end
      end

      # The probe's spelling for a process that holds the row's secrets:
      # redaction first, then the one escaper.
      def shown(redact) = ->(text) { escape(redact.call(text.to_s)) }

      def clock_word(stamp)
        Time.iso8601(stamp.to_s).localtime.strftime("%Y-%m-%d %H:%M:%S")
      rescue ArgumentError
        stamp.to_s
      end

      def status_document(status)
        { "state" => status.state.to_s, "reason" => status.reason, "issuer" => status.issuer, "scope" => status.scope,
          "issued_at" => status.issued_at, "refresh_token" => status.refresh_token, "optional" => status.optional }
      end

      def print_tools(out, server)
        tools = server.fetch("tools")
        skipped = server.fetch("skipped")
        out.puts "  tools:   #{tools.length} announced of #{tools.length + skipped.length} listed — " \
                 "#{number(server.fetch("bytes"))} bytes"
        width = tools.map { |tool| tool.fetch("name").length }.max.to_i
        tools.each do |tool|
          out.puts "    #{tool.fetch("name").ljust(width)}  #{number(tool.fetch("bytes"))} bytes  " \
                   "#{profile_word(tool.fetch("profile"))} (#{tool.fetch("profile_source")})"
          tool.fetch("underivable").each do |property|
            out.puts "    #{" " * width}  incubation deny not derivable for #{property.inspect}"
          end
        end
        return if skipped.empty?

        out.puts "    skipped: #{skipped.map { |entry| "#{entry.fetch("raw")} (#{entry.fetch("reason")})" }.join(", ")}"
      end

      # The documents: each announced name with its kind — a
      # resource with the listing's mimeType — and the skips with their
      # reasons, by the name they WOULD have been announced under.
      def print_documents(out, server)
        documents = server.fetch("documents")
        skipped = server.fetch("skipped_documents")
        return if documents.empty? && skipped.empty?

        out.puts "  documents: #{documents.length} announced of #{documents.length + skipped.length} listed"
        out.puts "    #{documents.map { |document| document_word(document) }.join("  ")}" unless documents.empty?
        return if skipped.empty?

        out.puts "    skipped: #{skipped.map { |entry| "#{entry.fetch("name")} (#{entry.fetch("reason")})" }.join(", ")}"
      end

      def document_word(document)
        inside = [document.fetch("kind"), document["mime_type"]].compact.join(", ")
        "#{document.fetch("name")} (#{inside})"
      end

      def profile_word(profile)
        words = [profile["kind"]]
        words << "destructive" if profile["destructive"] == true
        words << profile["world"]
        words.compact.join("/")
      end

      def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      # ---- rho mcp probe NAME ----

      # A row with no `tools` is probed AS IF it said `"*"` — the refusal
      # sentence promises this verb prints what it would declare and the
      # bytes — under the config sentence the daemon lists it with; any
      # other fault prints its sentence and connects nothing.
      def probe(cli, name)
        row = settings_row(cli, name)
        probe_row(cli, row) unless row.nil?
      end

      # The PERSON'S table as THIS process reads it: the test seam, else
      # rho's `Config` (the only reader of the file); none where rho is not
      # loaded and no seam names one.
      def person_table(cli)
        Rho::Mcp.settings_table || (Rho::Config.load(cli.home.settings_path).mcp_servers if defined?(Rho::Config)) || {}
      end

      # The table every verb reads: the person's under the shipped example.
      def settings_table(cli) = Builtin.under(person_table(cli))

      # The settings rows as THIS process parses them (its own `ENV`).
      def rows(cli)
        Settings.parse(settings_table(cli), env: ENV, home: cli.home.root)
      end

      # One row by name, its config fault printed as the daemon would list
      # it and nil answered; a row whose only fault is no `tools` is taken
      # as `"*"`.
      def settings_row(cli, name)
        raw = settings_table(cli)[name]
        refuse("no mcp server named #{name.inspect} in #{cli.home.settings_path}") if raw.nil?

        row = Settings.parse({ name => raw }, env: ENV, home: cli.home.root).fetch(0)
        return row unless row.is_a?(Settings::Fault)

        cli.out.puts "server:    #{name}  down: config: #{row.sentence}"
        return nil if raw.key?("tools")

        row = Settings.parse({ name => raw.merge("tools" => Settings::ALL_TOOLS) }, env: ENV, home: cli.home.root).fetch(0)
        row.is_a?(Settings::Fault) ? nil : row
      end

      # The connection is this verb's own — its own group, its own
      # `ensure` — and the tools are curated exactly as the daemon would;
      # an OAuth row connects on its storage's READ-ONLY view (nothing
      # refreshed, nothing cleared, nothing written).
      def probe_row(cli, row)
        storage = Oauth.storage_for(row, home: cli.home)
        redact = Rho::Runner::Redact.new(row.secrets, live: storage)
        connection = Connection.new(row, redact: redact, transport_factory: Rho::Mcp.transport_factory,
          storage: storage&.read_only)
        begin
          connection.open!
        rescue Unavailable => error
          cli.out.puts "server:    #{row.key}  #{row.transport}  #{row.launch}  down: #{shown(redact).call(error.message)}"
          return nil
        end
        begin
          print_probe(cli.out, row, connection, redact)
        ensure
          connection.close
        end
      end

      # ---- rho mcp enable NAME / rho mcp disable NAME ----

      # The switch, into the person's file: the whole `mcp_servers` object
      # rebuilt with that one row's `enabled` set — a partial row for a
      # name the person never wrote (the shipped example's overlay), every
      # other member kept for one they did. A state already held writes
      # nothing.
      def switch(cli, name, enabled)
        person = person_table(cli)
        unless person.key?(name) || Builtin::ROWS.key?(name)
          refuse("no mcp server named #{name.inspect} — not built in, and not in #{cli.home.settings_path}")
        end
        if enabled?(settings_table(cli).fetch(name)) == enabled
          cli.out.puts "#{name} is already #{enabled ? "enabled" : "disabled"}"
          return nil
        end

        row = (Hash.try_convert(person[name]) || {}).merge(Settings::ENABLED => enabled)
        table = person.merge(name => row)
        cli.home.write_setting("mcp_servers", table)
        cli.out.puts(enabled ? "enabled #{name} — the daemon connects it at its next boot (`rho restart`)" :
                               "disabled #{name} — the daemon drops it at its next boot (`rho restart`)")
        table
      end

      # The effective switch of a raw row: absent is on, and only `true` is.
      def enabled?(raw) = Hash.try_convert(raw)&.fetch(Settings::ENABLED, true) == true

      # ---- rho mcp login NAME / rho mcp logout NAME ----

      def login(cli, name, options)
        row = oauth_row(cli, name)
        return nil if row.nil?

        Oauth::Login.call(cli, row, oauth_storage(cli, row), options, browser: browser_launcher(cli))
      end

      def logout(cli, name)
        row = oauth_row(cli, name)
        return nil if row.nil?

        Oauth::Logout.call(cli, row, oauth_storage(cli, row))
      end

      # The row, or the reason it is not an OAuth row's — its own sentence.
      def oauth_row(cli, name)
        row = settings_row(cli, name)
        return nil if row.nil?

        reason = if !row.http? then "is not an http server"
        elsif row.authorization_header? then "carries an Authorization header — the static-bearer door"
        elsif !row.secure_url? then "is on plain http:// off loopback"
        end
        refuse("mcp server \"#{name}\" #{reason}") if reason
        row
      end

      def oauth_storage(cli, row)
        Oauth.storage_for(row, home: cli.home) || refuse("mcp server \"#{row.key}\": #{NO_HOME}")
      end

      # The ONE launcher, where rho is loaded (the CLI process is): answers
      # whether an opener started (`Rho::Cli::Browser.launch` prints the
      # reason it did not and never raises); nil where none is loaded.
      def browser_launcher(cli)
        return nil unless defined?(Rho::Cli::Browser)

        ->(url) { Rho::Cli::Browser.launch(url, out: cli.out) }
      end

      def print_probe(out, row, connection, redact)
        shown = shown(redact)
        out.puts "server:    #{row.key}  #{row.transport}  #{row.launch}  serves #{row.serves}  " \
                 "#{connected_word(connection.pid, connection.group_pid)}  #{shown.call(connection.protocol_version)}  " \
                 "#{identity_word(connection.server_name, connection.server_version, shown)}"
        out.puts "  capabilities: #{Array(connection.server_capabilities&.keys).join(", ")}"
        out.puts "  instructions: #{escape(redact.call(connection.instructions.to_s))}" unless connection.instructions.to_s.empty?
        curated = Curation.curate(row, connection.tools)
        out.puts "  would be down: #{curated.fault}" if curated.fault
        print_probe_tools(out, row, connection.tools, curated, redact)
        print_probe_documents(out, row, connection, redact)
        out.puts "  env:     #{row.env.keys.map { |name| "#{name}=#{Rho::Runner::Redact::MASK}" }.join("  ")}" unless row.env.empty?
        out.puts "  headers: #{row.headers.keys.map { |name| "#{name}: #{Rho::Runner::Redact::MASK}" }.join("  ")}" unless row.headers.empty?
      end

      def print_probe_tools(out, row, tools, curated, redact)
        by_name = curated.announced.to_h { |entry| [entry.raw_name, entry] }
        skipped = curated.skipped.to_h { |entry| [entry.raw_name, entry.reason] }
        out.puts "  tools:   #{tools.length} listed — #{curated.announced.length} would be announced, " \
                 "#{number(curated.bytes)} bytes"
        tools.each do |tool|
          raw = tool.name.to_s
          public_name = Naming.tool(row.key, raw)
          entry = by_name[raw]
          schema = Hash.try_convert(tool.input_schema) || {}
          bytes = entry ? entry.bytes : Curation.bytes(public_name, tool.description.to_s, schema)
          line = "    #{public_name}  #{number(bytes)} bytes"
          line += "  skipped: #{skipped[raw]}" if skipped.key?(raw)
          line += "  (#{entry.profile_source})" if entry
          out.puts line
          out.puts "      description (#{tool.description.to_s.bytesize} bytes): #{escape(redact.call(tool.description.to_s))}"
          risky = schema.keys.map(&:to_s) & RISKY_SCHEMA_KEYS
          out.puts "      #{risky.join(", ")}: a provider may refuse this schema" unless risky.empty?
          underivable(public_name, schema).each do |property|
            out.puts "      incubation deny not derivable for #{property.inspect}"
          end
        end
      end

      # The documents as the daemon would announce them — every prompt and
      # resource with the name it WOULD be announced under, its
      # description's bytes, and the reason it would be skipped — then the
      # resource templates, which are never documents.
      def print_probe_documents(out, row, connection, redact)
        curated = Documents.curate(row, connection.prompts, connection.resources)
        listed = connection.prompts.length + connection.resources.length
        out.puts "  documents: #{listed} listed — #{curated.announced.length} would be announced" if listed.positive?
        skipped = curated.skipped.to_h { |entry| [entry.name, entry.reason] }
        (connection.prompts.map { |p| [p, "prompt"] } + connection.resources.map { |r| [r, "resource"] }).each do |listing, kind|
          raw = listing["name"].to_s
          name = Naming.document(row.key, raw.empty? ? listing["uri"].to_s : raw)
          line = "    #{name}  (#{[kind, listing["mimeType"]].compact.join(", ")})"
          line += "  skipped: #{skipped[name]}" if skipped.key?(name)
          out.puts line
          description = listing["description"].to_s
          out.puts "      description (#{description.bytesize} bytes): #{escape(redact.call(description))}" unless description.empty?
        end
        templates = connection.resource_templates
        return if templates.empty?

        out.puts "  resource_templates: #{templates.length} listed (never a document)"
        templates.each do |template|
          out.puts "    #{escape(redact.call(template["name"].to_s))}  #{escape(redact.call(template["uriTemplate"].to_s))}"
        end
      rescue StandardError => error
        out.puts "  documents: could not list (#{redact.call(error.message)})"
      end

      # The properties a deny cannot be derived from (`Rho::LoopRequest`,
      # when rho is loaded — the CLI and the daemon both load it).
      def underivable(public_name, schema)
        return [] unless defined?(Rho::LoopRequest)

        Rho::LoopRequest.deny_properties("name" => public_name, "input_schema" => schema).skipped
      end

      # What the model reads, shown honestly: a newline is `\n`, a tab
      # `\t`, every invisible or control character its `\u{…}` dump.
      def escape(text)
        text.to_s.gsub(/[\n\t\r]|#{INVISIBLE}/) do |char|
          case char
          when "\n" then "\\n"
          when "\t" then "\\t"
          when "\r" then "\\r"
          else format("\\u{%X}", char.ord)
          end
        end
      end
    end
  end
end
