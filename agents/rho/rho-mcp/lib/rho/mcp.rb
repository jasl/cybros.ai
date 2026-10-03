require "rho/runner"
require_relative "mcp/version"
require_relative "mcp/errors"
require_relative "mcp/naming"
require_relative "mcp/settings"
require_relative "mcp/builtin"
require_relative "mcp/mapping"
require_relative "mcp/stdio_transport"
require_relative "mcp/http_transport"
require_relative "mcp/oauth"
require_relative "mcp/connection"
require_relative "mcp/curation"
require_relative "mcp/budget"
require_relative "mcp/documents"
require_relative "mcp/conversations"
require_relative "mcp/commands"

module Rho
  # MCP, AS AN EXTENSION. An MCP server is a
  # tool source behind an executor: rho runs the client, curates what the
  # operator named, announces each tool VERBATIM under its own prefix with
  # the worst-case effect profile, and the kernel — which never speaks MCP
  # — addresses, judges and settles the call exactly as it does `bash`.
  # One extension gem beside `rho-browser`, one settings key, no kernel
  # change.
  #
  # THE CONNECTION HAPPENS AT LOAD, inside `register(api)`: a tool is
  # registered through `api.register_tool`, the handle freezes after the
  # factory returns, and a server's tool set is known only after
  # `initialize` + `tools/list` — so the list is fetched here, per server,
  # under a bound that is enforced (`startup_timeout_ms`), servers
  # connected SERIALLY in settings order. The CLI process runs `register`
  # too, to learn the verbs; its host says `serving_tools: false` and
  # nothing is spawned there (`rho mcp probe NAME` connects on demand).
  #
  # MODULE STATE, THE BROWSER'S PATTERN: one `Connection` per server key
  # under a LOCK, `close!` on `:shutdown` — the connections taken OUT
  # under the lock and closed OUTSIDE it in parallel threads, each under
  # the ladder's bound, so N servers cost one ladder and a worker's call
  # never blocks on the lock through a teardown — `reset!` for tests.
  # Faults are PER SERVER (a row down at boot keeps every other server
  # announced); any raise out of `register` after a spawn tears every
  # child built so far down in an `ensure`, because the loader commits
  # nothing of a handle that raised — its shutdown hook included.
  #
  # PROMPTS AND RESOURCES ARE DOCUMENTS ON THE SERVER'S ROW:
  # curated at load into `{name, description}` entries handed to the plane
  # through `api.describe_documents(serves:)`, loaded through
  # `api.load_document(serves:)` by the address's `skill` tool — Coding's
  # on the runner address; on the AGENT address this extension registers
  # the plane's `Tools::Skill` itself, when an http server announced a
  # document there. A document name met on two servers keeps the first
  # (the kernel refuses a repeated name for the whole announcement).
  #
  # THE TABLE IS THE PERSON'S UNDER THE SHIPPED EXAMPLE (`Builtin`): the
  # one row the gem carries (Context7, disabled) is merged under the
  # person's `mcp_servers` at every read — here at load, and in the CLI's
  # verbs — so a fresh home lists it with its switch, and `rho mcp enable
  # context7` writes the one member that turns it on. A DISABLED row (the
  # switch, `Row#enabled?`) is an `Entry` in state `disabled`: listed with
  # its storage (so the `auth:` line is true), connected to never,
  # announced never — judged before the mode, so a parked row on the wrong
  # address has nothing to say.
  #
  # THE EDITOR'S SERVERS ARE A SECOND TABLE: an ACP client's `mcpServers` arrive per conversation
  # through the daemon's door and the seam `register(api)` registers —
  # `api.register_conversation_servers { |anchor, entries| set }`, the ONE
  # registrar a daemon accepts — and `Conversations.open` connects them
  # through the same `connect` the boot table uses, onto the AGENT slot
  # (the servers run beside the editor), each set held here for the
  # report and the shutdown ladder while the daemon holds it per anchor.
  # `close!` closes every live set with the boot connections under one
  # ladder, and a registrar call after it answers `Closed`.
  module Mcp
    NAME = "rho.mcp".freeze
    LOCK = Mutex.new
    # ADR-0040's byte case: rho's whole toolset is 4,971 bytes, Playwright's
    # MCP list 18.5–47 KB — "measure bytes before adopting; curation is
    # explicit". The WARN line on every boot past it. The one WALL is the
    # kernel's `envelope_bound` on an address's whole announcement, met
    # per server by `Budget`.
    REFERENCE_TOOLSET_BYTES = 4971
    # `close!` joins each ladder past its own bound (3 stages × 3 s).
    CLOSE_JOIN_SECONDS = 12.0

    # One server as this process holds it: the parsed row (or the config
    # fault), the connection when one was made, the curation when the
    # tools were announced, the documents curated beside them, the
    # boot-time reason it is down, and an OAuth row's storage (read by
    # the report whether or not the row connected).
    Entry = Data.define(:key, :row, :connection, :curated, :documents, :fault, :state, :storage) do
      def initialize(documents: nil, storage: nil, **members) = super

      def connected? = connection&.connected? || false

      def announces?(serves, name) = row.serves == serves && !documents.nil? && !documents.find(name).nil?

      # `[state, detail]` as `rho mcp` reads them: the boot-time state and
      # fault, unless the row connected and its connection has since
      # recorded an exit — then `down` with that record.
      def status
        return [state, fault] unless state == "connected"

        down = connection&.down
        down ? ["down", down] : ["connected", nil]
      end
    end

    class << self
      # THE TWO SEAMS A TEST USES, the browser's `driver_factory` shape:
      # the settings table (else the host's `Config#mcp_servers`) and the
      # transport a row is connected through (else the real one by
      # transport: the stdio child in its own group, or the gem's HTTP
      # client on Faraday's default adapter with the row's two clocks and,
      # for an OAuth row whose storage holds tokens, the headless provider
      # the CONNECTION built at this `open!`).
      attr_writer :settings_table, :transport_factory

      def settings_table = @settings_table

      def transport_factory
        @transport_factory ||= lambda do |row, read_timeout:, oauth: nil|
          if row.stdio?
            StdioTransport.new(command: row.command, args: row.args, env: child_env(row), cwd: row.cwd,
              read_timeout: read_timeout)
          else
            HttpTransport.new(url: row.url, headers: row.headers, oauth: oauth,
              open_timeout: row.startup_timeout_ms / 1000.0, timeout: row.timeout_ms / 1000.0)
          end
        end
      end

      # THE ENVIRONMENT IS REPLACED, NOT MERGED: the runner's
      # scrub (`ChildEnv.scrubbed` — Bundler's trail dropped, the locale re-applied, credential-shaped names and rho's own withheld; the one scrub every third party's child is spawned under) PLUS the row's `env` — the hash a third party's
      # long-lived process gets whole, under `unsetenv_others: true` at
      # the spawn site.
      def child_env(row, current = ENV.to_h)
        Rho::Runner::ChildEnv.scrubbed(current).merge(row.env)
      end

      def entries = LOCK.synchronize { (@entries || {}).dup }

      def connections = entries.transform_values(&:connection).compact

      # THE CALL a tool class makes: the server's connection, or `ServerGone`
      # when this process never connected it.
      def call(server_key, raw_name, args, env: nil, public_name: Naming.tool(server_key, raw_name))
        entry = LOCK.synchronize do
          raise Closed, "the mcp host is shutting down" if @closed

          (@entries || {})[server_key]
        end
        connection = entry&.connection
        raise ServerGone, "mcp server #{server_key} is not connected in this process" if connection.nil?

        connection.call_tool(raw_name, args, public_name: public_name, env: env)
      end

      # THE ANNOUNCEMENT'S DOCUMENTS on one address: every connected
      # server's curated entries, in settings order — the block
      # `describe_documents(serves:)` answers at placement and on `rho env`.
      def documents_for(serves)
        entries.values.flat_map { |entry| entry.row.serves == serves && entry.documents ? entry.documents.entries : [] }
      end

      # THE LOAD the address's `skill` addresses here: the document's server
      # answers a prompt's text or a resource's contents; nil for a name no
      # server of this address announced (the walk falls through).
      def load_document(serves, name, env)
        entry = LOCK.synchronize do
          raise Closed, "the mcp host is shutting down" if @closed

          (@entries || {}).values.find { |candidate| candidate.announces?(serves, name) }
        end
        return nil if entry.nil?

        document = entry.documents.find(name)
        if document.prompt?
          entry.connection.load_prompt(document.raw_name, name: name, env: env)
        else
          entry.connection.load_resource(document.uri, name: name, env: env)
        end
      end

      # The boot connections and every live conversation set's, taken out
      # under the lock and closed under one ladder.
      def close!
        taken = LOCK.synchronize do
          @closed = true
          current = @entries || {}
          sets = @conversations || []
          @entries = {}
          @conversations = []
          current.values.filter_map(&:connection) + sets.flat_map(&:detach)
        end
        close_all(taken)
      end

      # For tests: forget everything — the seams too — in one critical section.
      def reset!
        taken = LOCK.synchronize do
          current = @entries || {}
          sets = @conversations || []
          @entries = {}
          @conversations = []
          @ledger = nil
          @closed = false
          @settings_table = nil
          @transport_factory = nil
          @log = nil
          current.values.filter_map(&:connection) + sets.flat_map(&:detach)
        end
        close_all(taken)
      end

      # THE LIVE CONVERSATION SETS, in open order.
      def conversations = LOCK.synchronize { (@conversations || []).dup }

      # A set opened through the registrar joins the live list — or, when
      # `close!` ran meanwhile, is refused `Closed` (the caller closes what
      # it built): a set held past the ladder would be a child nobody holds.
      def hold_conversation(set)
        LOCK.synchronize do
          raise Closed, "the mcp host is shutting down" if @closed

          @conversations = (@conversations || []) + [set]
        end
        set
      end

      def release_conversation(set)
        LOCK.synchronize { @conversations = (@conversations || []) - [set] }
        nil
      end

      # THE LEDGER A CONVERSATION SET IS BUDGETED ON: what the boot table
      # left on each address, plus every live set's kernel entries on the
      # agent's — the union the daemon announces there.
      def ledger
        boot, sets = LOCK.synchronize { [@ledger || {}, (@conversations || []).dup] }
        boot.merge(agent: Array(boot[:agent]) + sets.flat_map(&:kernel_entries))
      end

      # The document `GET /mcp` answers and `rho mcp` prints: the boot
      # rows in settings order, then every live conversation set's rows
      # with their owner (the anchor), in open order.
      def report
        listed = entries.values.map { |entry| server_document(entry) } +
          conversations.flat_map { |set| set.entries.map { |entry| server_document(entry, owner: set.anchor) } }
        { "servers" => listed,
          "total" => { "tools" => listed.sum { |server| server["tools"].length },
                       "bytes" => listed.sum { |server| server["bytes"] },
                       "documents" => listed.sum { |server| server["documents"].length } } }
      end

      def register(api)
        @log = api.log
        built = []
        table = Builtin.under(settings_table || api.host&.config&.mcp_servers || {})
        rows = Settings.parse(table, env: ENV, home: api.host&.home&.root || Dir.pwd)
        budget = Budget.new(api.announced)
        entries = dedupe_documents(rows.to_h { |row| [row.key, entry_for(api, row, built, budget)] })
        register_documents(api, entries)
        api.register_route("GET", "/mcp") { |_request, _ctx| [200, report] }
        api.register_command("mcp", usage: Commands::USAGE, description: Commands::DESCRIPTION,
          options: Commands::OPTIONS) do |cli, args, options|
          Commands.run(cli, args, options)
        end
        register_conversation_servers(api)
        api.on(:shutdown) { close! }
        LOCK.synchronize do
          raise Closed, "the mcp host is shutting down" if @closed

          @entries = entries
          @ledger = budget.ledger
        end
      rescue StandardError, ScriptError
        # A handle that raised commits nothing — its shutdown hook included —
        # so a child alive now would be a group nobody holds.
        close_all(built)
        raise
      end

      # THE CONNECT HALF, SHARED: the boot
      # table's `entry_for` and `Conversations.open` connect a row the same
      # way — the row's redactor over its secrets (and an OAuth row's live
      # store), `Connection#open!` under the startup bound, the tools
      # curated and judged against the address's budget — and get an
      # `Entry`: `down` with its sentence (the child closed, nothing of it
      # kept), or `connected` with the curated classes, NOT yet announced
      # or logged (the boot half registers them on `api` and logs after
      # the documents; a conversation set hands them to the daemon).
      # `built` collects every connection made, for the caller's `ensure`;
      # the block, handed the connection, answers the `caller` the classes
      # close over (none: the module's `call`, by boot key; a conversation's
      # is THAT connection); `owner` names the conversation on the lines;
      # `log` is the host's (the handle's at load, the seam's after).
      def connect(row, built, budget, storage: nil, owner: nil, log: @log)
        redact = Rho::Runner::Redact.new(row.secrets, live: storage)
        connection = Connection.new(row, log: redacting_log(redact, log), redact: redact,
          transport_factory: transport_factory, clock: -> { Time.now }, storage: storage)
        begin
          connection.open!
        rescue Unavailable => error
          log&.warn("mcp.server_unavailable", **ident(row, owner), reason: redact.call(error.message))
          return Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: error.message, state: "down",
            storage: storage)
        end
        built << connection
        caller = block_given? ? yield(connection) : Rho::Mcp.method(:call)
        curated = budget.judge(row, Curation.curate(row, connection.tools, caller: caller))
        if curated.fault
          connection.close
          built.delete(connection)
          log&.warn("mcp.server_unavailable", **ident(row, owner), reason: redact.call(curated.fault))
          return Entry.new(key: row.key, row: row, connection: nil, curated: curated, fault: curated.fault, state: "down",
            storage: storage)
        end

        Entry.new(key: row.key, row: row, connection: connection, curated: curated, fault: nil, state: "connected",
          storage: storage)
      end

      # The two lines a connected row writes: the connection's identity
      # and lists, then the announcement's bytes (WARN past ADR-0040's
      # reference) — `conversation:` beside `server:` on an editor's row.
      def log_connected(row, connection, curated, documents: nil, owner: nil, log: @log)
        log&.info("mcp.connected", **ident(row, owner), protocol_version: connection.protocol_version,
          server_name: connection.server_name || "(unnamed)", server_version: connection.server_version,
          tools: connection.tools.length, prompts: connection.prompts.length, resources: connection.resources.length)
        level = curated.bytes > REFERENCE_TOOLSET_BYTES ? :warn : :info
        log&.public_send(level, "mcp.announced", **ident(row, owner), tools: curated.announced.length,
          bytes: curated.bytes, reference_bytes: REFERENCE_TOOLSET_BYTES, documents: documents&.announced&.length || 0)
      end

      # The shutdown ladder: the connections closed in parallel threads,
      # each joined past its own bound, outside every lock.
      def close_all(connections)
        threads = connections.map do |connection|
          Thread.new do
            connection.close
          rescue StandardError
            nil
          end
        end
        threads.each { |thread| thread.join(CLOSE_JOIN_SECONDS) }
        nil
      end

      private

        def serving_tools?(api)
          host = api.host
          host.nil? || host.serving_tools
        end

        # THE SEAM: the editor's `mcpServers`
        # reach the daemon's door per conversation in the ACP shape; the
        # daemon holds the per-anchor table and calls the ONE registrar it
        # accepts — this one — for a new or changed set. After `close!` the
        # registrar answers `Closed` (the daemon maps it to 503
        # `unavailable`): a set opened past the ladder would be a child
        # nobody holds; `hold_conversation` closes the gate under the lock
        # for a set that connected while the ladder ran. The base handle
        # (a standalone runner) has no conversations and answers the verb
        # as it answers every daemon verb — with a log line.
        def register_conversation_servers(api)
          api.register_conversation_servers do |anchor, entries|
            LOCK.synchronize { raise Closed, "the mcp host is shutting down" if @closed }
            Conversations.open(anchor, entries, api: api, log: @log)
          end
        end

        def ident(row, owner)
          owner ? { server: row.key, conversation: owner } : { server: row.key }
        end

        def entry_for(api, row, built, budget)
          if row.is_a?(Settings::Fault)
            @log&.warn("mcp.server_config_invalid", server: row.key, sentence: row.sentence)
            return Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: "config: #{row.sentence}",
              state: "down")
          end
          return disabled_entry(api, row) unless row.enabled?
          unless api.serves?(row.serves)
            sentence = mode_sentence(api, row)
            @log&.warn("mcp.server_config_invalid", server: row.key, sentence: sentence)
            return Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: "config: #{sentence}",
              state: "down")
          end
          return Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: nil, state: "unconnected") unless
            serving_tools?(api)

          connect_and_announce(api, row, built, budget)
        end

        # The switch is off: nothing built, nothing announced; the storage
        # alone, so a login made before the enable shows on the `auth:` line.
        def disabled_entry(api, row)
          Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: nil, state: "disabled",
            storage: Oauth.storage_for(row, home: api.host&.home, log: @log))
        end

        def mode_sentence(api, row)
          mode = api.host&.config&.mode || "runner"
          if row.serves == :agent
            "mcp server \"#{row.key}\" serves the agent (transport #{row.transport}); this rho runs in mode #{mode} — " \
              "set \"serves\": \"runner\" for a server this machine owns, or declare it in the agent's settings"
          else
            "mcp server \"#{row.key}\" serves the runner (transport #{row.transport}); this rho runs in mode #{mode} " \
              "and serves no tool of its own — declare the server on the runner's home, or use mode full"
          end
        end

        # THE ANNOUNCE HALF of a boot row: an OAuth row's storage is built
        # here, beside the row's redactor (the live set), when this host
        # has a home to hold one; the connected row's classes registered on
        # the handle and its documents curated beside them.
        def connect_and_announce(api, row, built, budget)
          storage = Oauth.storage_for(row, home: api.host&.home, log: @log)
          entry = connect(row, built, budget, storage: storage)
          return entry unless entry.state == "connected"

          connection = entry.connection
          entry.curated.classes.each { |klass| api.register_tool(klass, serves: row.serves) }
          documents = Documents.curate(row, connection.prompts, connection.resources)
          log_connected(row, connection, entry.curated, documents: documents)
          entry.with(documents: documents)
        end

        # A document name two servers fold to (`a-b` + `c`, `a` + `b-c`) is
        # announced once, by the first in settings order; the second lists
        # it skipped, naming the first — a fact of the pair, judged here
        # where every row is known.
        def dedupe_documents(entries)
          taken = {}
          entries.transform_values do |entry|
            next entry if entry.documents.nil?

            kept = []
            skipped = entry.documents.skipped.dup
            entry.documents.announced.each do |document|
              owner = taken[[entry.row.serves, document.name]]
              if owner
                skipped << Documents::Skipped.new(name: document.name, kind: document.kind,
                  reason: "#{document.kind}: name #{document.name} is already announced by server #{owner.inspect}")
              else
                taken[[entry.row.serves, document.name]] = entry.key
                kept << document
              end
            end
            entry.with(documents: Documents::Curated.new(announced: kept.freeze, skipped: skipped.freeze))
          end
        end

        # THE PLANE SEAM: the documents and their loader on each
        # address this host serves; the plane's `skill` on the AGENT address
        # when a server announced a document there (Coding serves it on the
        # runner's; in agent mode Coding is not loaded at all).
        def register_documents(api, entries)
          Rho::Runner::Extensions::Api::SERVES.each do |serves|
            next unless api.serves?(serves)

            api.describe_documents(serves: serves) { |_environment| documents_for(serves) }
            api.load_document(serves: serves) { |name, env| load_document(serves, name, env) }
          end
          return unless api.serves?(:agent) &&
            entries.values.any? { |entry| entry.row.serves == :agent && entry.documents&.announced&.any? }

          api.register_tool(Rho::Runner::Tools::Skill, serves: :agent)
        end

        # Every `mcp.*` line a connection writes passes the row's redaction.
        def redacting_log(redact, log)
          return nil if log.nil?

          RedactingLog.new(log, redact)
        end

        # One row's document; `owner` names the conversation an editor's
        # row belongs to (a boot row has none, and no `owner` member).
        def server_document(entry, owner: nil)
          row = entry.row
          connection = entry.connection
          state, detail = entry.status
          tools = entry.curated&.announced || []
          {
            "key" => entry.key, "transport" => row.transport, "serves" => row.serves&.to_s,
            **(owner ? { "owner" => owner } : {}),
            "launch" => row.launch,
            "state" => state, "detail" => detail,
            "pid" => connection&.pid, "pgid" => connection&.group_pid,
            "protocol_version" => connection&.protocol_version,
            "server_name" => connection&.server_name, "server_version" => connection&.server_version,
            "tools" => tools.map { |tool| tool_document(tool) },
            "skipped" => (entry.curated&.skipped || []).map { |skip| { "raw" => skip.raw_name, "reason" => skip.reason } },
            "bytes" => tools.sum(&:bytes),
            "documents" => (entry.documents&.announced || []).map { |document| document_document(document) },
            "skipped_documents" => (entry.documents&.skipped || []).map do |skip|
              { "name" => skip.name, "kind" => skip.kind, "reason" => skip.reason }
            end,
            "env" => row.env.keys,
            "headers" => row.headers.keys,
            "auth" => auth_document(entry, conversation: !owner.nil?),
          }
        end

        # THE `auth` MEMBER: the door the row
        # uses and, for an OAuth row, the store's read-only state — keys,
        # issuer, scope, a clock, two booleans (the refresh token held, the
        # authorization optional); never a value. An editor's row has no
        # login door in rho (its headers are the editor's credential;
        # `rho mcp login` reads settings rows alone): header or none.
        def auth_document(entry, conversation: false)
          row = entry.row
          return { "kind" => "none" } unless row.http?
          return { "kind" => "header" } if row.authorization_header?
          return { "kind" => "none" } if conversation || !row.oauth?
          return { "kind" => "oauth", "state" => "needs_login", "reason" => "this host has no rho home to hold a login" } if entry.storage.nil?

          status = entry.storage.status
          { "kind" => "oauth", "state" => status.state.to_s, "reason" => status.reason, "issuer" => status.issuer,
            "scope" => status.scope, "issued_at" => status.issued_at, "refresh_token" => status.refresh_token,
            "optional" => status.optional }
        end

        def document_document(document)
          { "name" => document.name, "kind" => document.kind, "raw" => document.raw_name, "mime_type" => document.mime_type }
        end

        def tool_document(tool)
          { "name" => tool.public_name, "raw" => tool.raw_name, "bytes" => tool.bytes, "profile" => tool.profile,
            "profile_source" => tool.profile_source,
            "underivable" => Commands.underivable(tool.public_name, tool.schema) }
        end
    end

    # A log whose every string field passes one row's redaction, so a
    # secret a connection would quote (a stderr tail, an error message)
    # never reaches the file.
    class RedactingLog
      def initialize(inner, redact)
        @inner = inner
        @redact = redact
      end

      %i[debug info warn error].each do |level|
        define_method(level) do |event, **fields|
          scrubbed = fields.transform_values { |value| value.is_a?(String) ? @redact.call(value) : value }
          @inner.public_send(level, event, **scrubbed)
        end
      end
    end
  end
end
