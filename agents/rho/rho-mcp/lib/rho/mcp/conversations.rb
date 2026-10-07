require "digest"
require "json"

module Rho
  module Mcp
    # THE EDITOR'S SERVERS, PER CONVERSATION: the table beside the boot table. An ACP client hands
    # `session/new` its `mcpServers`; the daemon's door forwards them, per
    # conversation, through the seam rho-mcp registered at load
    # (`api.register_conversation_servers` in `Rho::Mcp.register`), and
    # this module answers a `Set`: the rows connected THROUGH THE BOOT
    # TABLE'S OWN PATH (`Rho::Mcp.connect` — the row's redactor over its
    # secrets, `Connection#open!` under the row's startup bound,
    # `Curation.curate` into classes, `Budget#judge` against the kernel's
    # envelope bound), serially in the editor's order, faults per row. The
    # classes close over THEIR connection — never the module's boot table
    # (`Rho::Mcp.call` looks a boot key up, and two editors may both name
    # `fx`) — and a call after the set closed answers `Closed`.
    #
    # WHAT THE DAEMON OWNS, AND THIS MODULE DOES NOT (the seam): the
    # per-anchor TABLE (`Environments#servers`) — which set an anchor
    # holds; the digest gate ("a re-list is a boot": an equal digest is a
    # no-op, a down row stays down); the close on `:host_ended`; the agent
    # slot's union and its re-announcement; the NAME COLLISIONS with the
    # boot table or another anchor (a class whose public name is taken
    # with a different schema is faulted for that anchor and dropped from
    # its classes there). Here: the set's `classes`, `report`, `digest`
    # and `close`, and the module's memory of every live set — for `rho
    # mcp` and `GET /mcp` (`Rho::Mcp.report` lists them after the boot rows, each with its owner) and for the shutdown ladder.
    #
    # NO DOCUMENTS ride a conversation row: the editor's prompts and
    # resources are the editor's own surface; a conversation's extras are
    # tools alone. THE BUDGET is met per row on top of the boot table's
    # ledger AND every live set's kernel entries (`Rho::Mcp.ledger`): the
    # agent slot's announcement is the union the daemon declares, so a
    # name two sets share is counted twice here — conservative, never
    # past the bound.
    #
    # SECRETS: the rows' env and header values are
    # each row's `secrets` under its own `Redact` — the boot table's trio,
    # built by `Rho::Mcp.connect`; the rows live here, in memory, in
    # nothing the daemon persists, and the digest reads KEYS, never a
    # value.
    module Conversations
      # One conversation's servers as this process holds them: `entries`
      # in the editor's order (`Rho::Mcp::Entry`, the boot table's shape,
      # so `GET /mcp` renders both alike), the `digest` the daemon gates
      # re-assertions on, closed once. The rows are built INSIDE `new`
      # (the block, handed the set) because every class closes over
      # `closed?` — the set exists before its rows, and is whole when
      # `new` returns.
      class Set
        attr_reader :anchor, :digest, :entries
        # The kernel-shaped entries of the connected rows: what the sets
        # opened after this one are budgeted on top of.
        attr_reader :kernel_entries

        def initialize(anchor:, digest:)
          @anchor = anchor
          @digest = digest
          @lock = Mutex.new
          @closed = false
          @entries = yield(self).freeze
          @kernel_entries = @entries.flat_map do |entry|
            entry.state == "connected" ? Budget.entries_for(entry.curated) : []
          end.freeze
        end

        # The tool classes the daemon adds to the agent slot: every row
        # connected at open — `mcp__<name>__<tool>`, one class per curated
        # tool, each answering its NAME/DESCRIPTION/SCHEMA/EFFECT_PROFILE
        # as the registry's classes do; a down row's none. A connection
        # that died since keeps its classes: the next call restarts it,
        # as a boot row's does.
        def classes
          @entries.flat_map { |entry| entry.state == "connected" ? entry.curated.classes : [] }
        end

        # The seam's report — one row per entry: `state` and `fault` as
        # the boot table reads them (a connection that died since is
        # `down` with its record), the transport as the entry named it.
        def report
          @entries.map do |entry|
            state, fault = entry.status
            { name: entry.key, state: state, fault: fault, transport: entry.row.transport }
          end
        end

        def closed? = @lock.synchronize { @closed }

        # Every connection closed under the shutdown ladder
        # (`Rho::Mcp.close_all`, outside every lock), the set forgotten;
        # idempotent — a second close finds nothing to take.
        def close
          Rho::Mcp.close_all(detach)
          Rho::Mcp.release_conversation(self)
          nil
        end

        # Marks the set closed and takes its connections out ONCE — `close`
        # and `Rho::Mcp.close!` share it, so N sets cost one ladder at
        # shutdown.
        def detach
          @lock.synchronize do
            next [] if @closed

            @closed = true
            @entries.filter_map(&:connection)
          end
        end
      end

      module_function

      # The registrar's answer (`Rho::Mcp.register`): the rows from the
      # ACP shape (`Settings.from_acp` — a malformed entry raises
      # `ArgumentError` before anything connects), connected serially,
      # each fault its row's, the set held by the module — or refused
      # `Closed` when the host shut down meanwhile. A raise past a connect
      # closes every connection built so far: the loader's own rule one
      # level down.
      def open(anchor, entries, api:, log: api.log)
        built = []
        rows = Settings.from_acp(entries, home: api.host&.home&.root || Dir.pwd)
        budget = Budget.new(Rho::Mcp.ledger)
        set = Set.new(anchor: anchor, digest: digest(rows)) do |holder|
          rows.map { |row| entry_for(holder, row, built, budget, log) }
        end
        # Held BEFORE the line says it opened: a set the ladder refuses
        # meanwhile is closed below and was never a live one.
        Rho::Mcp.hold_conversation(set)
        log&.info("mcp.conversation_servers", conversation: anchor, servers: rows.length,
          connected: set.entries.count { |entry| entry.state == "connected" }, tools: set.classes.length,
          digest: set.digest)
        set
      rescue StandardError, ScriptError
        Rho::Mcp.close_all(built)
        raise
      end

      # Over NAME + LAUNCH + KEYS, never a value: the daemon's gate on a
      # re-assertion. Rows sorted by name, so an editor re-listing the
      # same servers in another order asserts the same set.
      def digest(rows)
        facts = rows.map do |row|
          launch = if row.fault? then nil
          elsif row.stdio? then [row.command, row.args]
          else row.url
          end
          [row.key, row.transport, launch, row.env.keys.sort, row.headers.keys.sort]
        end
        Digest::SHA256.hexdigest(JSON.generate(facts.sort_by(&:first)))
      end

      def entry_for(set, row, built, budget, log)
        if row.fault?
          log&.warn("mcp.server_config_invalid", server: row.key, conversation: set.anchor, sentence: row.sentence)
          return Entry.new(key: row.key, row: row, connection: nil, curated: nil, fault: row.sentence, state: "down")
        end

        entry = Rho::Mcp.connect(row, built, budget, owner: set.anchor, log: log) { |connection| caller_for(set, connection) }
        Rho::Mcp.log_connected(row, entry.connection, entry.curated, owner: set.anchor, log: log) if entry.state == "connected"
        entry
      end

      # What a class's `call` invokes: THAT connection — or `Closed` once
      # the set let it go (the daemon dropped the classes with the set; a
      # call already in flight meets this).
      def caller_for(set, connection)
        lambda do |_server_key, raw_name, args, env: nil, public_name:|
          raise Closed, "conversation #{set.anchor}'s mcp servers are closed" if set.closed?

          connection.call_tool(raw_name, args, public_name: public_name, env: env)
        end
      end
    end
  end
end
