require "digest"
require "json"

module Rho
  class Environments
    # THE SERVERS TABLE: the
    # editor's MCP servers per ANCHOR — the conversation whose record a
    # child's copy and a side's fork copy share, so their turns find the
    # parent's servers with no row of their own — bound by the door's
    # `mcp:` member, served on the AGENT slot (they must run beside the
    # editor; the slot exists in full and agent mode, so `--runner ID`
    # works), and closed on the anchor's `:host_ended` and the daemon's
    # `:shutdown`. The table holds what the ONE registrar (rho-mcp's,
    # `Extensions::Registrar`) answered: the SET, closed and replaced
    # whole, and the entries this anchor SERVES after the collision
    # judgement below. Under the tables' one monitor; replaced immutably.
    #
    # THE DIGEST GATES EVERY LATER ASSERTION: the list's names, launches
    # (command/args/url) and env/header KEYS — never a value — so an equal
    # list is a no-op and a down row stays down ("a re-list is a boot"); a moved list closes the held set and boots the new one.
    # SECRETS: env/header values live in the registrar's rows under its
    # own Redact; nothing here reads them, and no line below carries an
    # entry — counts, names and reasons alone.
    #
    # NAME COLLISIONS are judged here: a class whose public name the boot
    # table (the registry — settings.json's servers and rho's own) already
    # serves, or that ANOTHER anchor serves under a DIFFERENT announced
    # entry, faults its ROW for this anchor (`down: name taken by <owner>`)
    # and every class of that row is dropped; the SAME name with the SAME
    # entry from two anchors is ONE announced entry serving both (Zed's
    # two windows on one project) — each anchor's own class answers its
    # own calls, the runner dispatching by anchor (`Toolsets#for`). THE
    # ROW A CLASS BELONGS TO IS ITS `SERVER_KEY` (the seam's contract, the
    # report row's `name`), never its public name's prefix: rho-mcp folds
    # a name with bytes outside `[A-Za-z0-9_-]` ("My Server" → `mcp__My_Server__echo_<12hex>`), so the prefix
    # cannot find the row, and a class without the constant is the
    # registrar breaking the seam — raised by name, never guessed at.
    class Servers
      # What the table holds per anchor: the registrar's set, the entries
      # served (name → the registry's `Entry` over the class: the
      # announcement's one renderer and the shape two anchors' entries are
      # compared by; the runner's table builds its own tools over the
      # CLASSES, `Toolsets#for`), the daemon's digest of the list handed
      # over, and the rows the judgement faulted (row name → sentence).
      Held = Data.define(:set, :entries, :digest, :faults)
      # A bind's answer: the anchor's report and whether the served set moved.
      Bound = Data.define(:report, :changed)

      LAUNCH_KEYS = %w[type name command args url].freeze

      # The no-op gate's key, the daemon's own derivation over the list as
      # received (the registrar's `digest` is the set's word for the same
      # facts). A malformed entry digests as whatever it is; the registrar
      # refuses it a moment later.
      def self.digest(entries)
        facts = Array(entries).map do |entry|
          entry = Hash.try_convert(entry) || {}
          keys = Array(entry["env"] || entry["headers"]).filter_map { |pair| Hash.try_convert(pair)&.dig("name") }.sort
          [entry.slice(*LAUNCH_KEYS), keys]
        end
        Digest::SHA256.hexdigest(JSON.generate(facts))
      end

      # `registrar` is the loaded `Extensions::Registrar` or nil; `served`
      # the WHOLE registry — every address's names and announced entries,
      # the boot table a conversation's server may not shadow.
      def initialize(monitor:, log:, registrar:, served:)
        @monitor = monitor
        @log = log
        @registrar = registrar
        @served = served
        @held = {}.freeze
      end

      def registrar? = !@registrar.nil?

      # THE BIND: no registrar → 422 `mcp_unavailable`; `[]` → close and
      # drop; an equal digest → no-op (the held report, nothing changed);
      # else the held set is closed FIRST (a stdio server re-launched over
      # its predecessor's ports), the registrar asked — its ArgumentError
      # is the door's 400, its own `Rho::Runner::Error` the door's 503
      # `daemon_stopping`, the anchor then holding nothing either way (the
      # table moved: `Environments#bind_servers` reads that off `digest`)
      # — and the new set held, judged and reported. `changed` says the
      # served set moved past a Bound answer.
      def bind(anchor, entries)
        return unavailable if @registrar.nil?

        entries = Array(entries)
        return Bound.new(report: [], changed: drop(anchor, reason: "cleared")) if entries.empty?

        digest = Servers.digest(entries)
        held = self[anchor]
        return Bound.new(report: report(anchor), changed: false) if held && held.digest == digest

        drop(anchor, reason: "replaced") if held
        set = open(anchor, entries)
        return set if set in Daemon::Refusal

        begin
          served, faults = judge(anchor, set)
        rescue Rho::Runner::Extensions::RegistrationError => error
          # THE SEAM BROKEN (a class without `SERVER_KEY`): the registrar's
          # own bug, raised through the door as its 500 and logged by name
          # here — the set it answered is closed on the way out (a stdio
          # server would outlive its table otherwise), never held.
          @log&.error("mcp_servers.seam_violation", anchor: anchor, detail: error.message)
          close(Held.new(set: set, entries: {}.freeze, digest: digest, faults: {}.freeze), anchor, "seam_violation")
          raise
        end
        @monitor.synchronize { @held = @held.merge(anchor => Held.new(set: set, entries: served, digest: digest, faults: faults)).freeze }
        @log&.info("mcp_servers.bound", anchor: anchor, servers: entries.length, tools: served.length, faults: faults.length)
        Bound.new(report: report(anchor), changed: true)
      end

      # The rows as the set reports them — `{name, state, fault,
      # transport}` — a judged row overlaid `down` with its sentence.
      def report(anchor)
        held = self[anchor]
        return [] if held.nil?

        Array(held.set.report).map do |row|
          row = row.to_h.transform_keys(&:to_sym)
          fault = held.faults[row[:name].to_s]
          fault ? row.merge(state: "down", fault: fault) : row
        end
      end

      # ---- what the runner's `Toolsets` asks (its `extras` duck) ----

      # `[classes, digest]` for the anchor — the served classes and the
      # digest that keys the runner's memo; none for an anchor without a set.
      def call(anchor)
        held = self[anchor]
        held ? [held.entries.values.map(&:klass), held.digest] : [[], nil]
      end

      # The anchor whose editor serves a name, for the refusal a call from
      # any other conversation meets; nil for a name nobody serves.
      def owner_of(name) = @monitor.synchronize { @held.find { |_anchor, held| held.entries.key?(name.to_s) }&.first }

      # Every anchor's served names, a name once.
      def names = all.flat_map { |held| held.entries.keys }.uniq

      def names_for(anchor) = self[anchor]&.entries&.keys || []

      # ---- what the announcement and the declaration read ----

      # Every anchor's served entries beyond the registry's, rendered as the
      # registry renders its own (`Entry#announcement`), a name once (the
      # same name from two anchors is one entry), sorted by name.
      def announcement
        all.flat_map { |held| held.entries.values }
          .uniq(&:name).map(&:announcement).sort_by { |entry| entry.fetch("name") }
      end

      def announcement_for(anchor)
        Array(self[anchor]&.entries&.values).map(&:announcement).sort_by { |entry| entry.fetch("name") }
      end

      # One digest over every anchor's held list: what moves when any set moves.
      def digest
        Digest::SHA256.hexdigest(JSON.generate(@monitor.synchronize { @held.transform_values(&:digest).sort }))
      end

      # ---- the ends ----

      # THE CONVERSATION ENDED HERE: its set is closed
      # and dropped; answers whether anything left the table.
      def host_ended(anchor) = drop(anchor, reason: "host_ended")

      # THE DAEMON STOPS: every set closed, the table emptied.
      def shutdown
        emptied = @monitor.synchronize do
          held = @held
          @held = {}.freeze
          held
        end
        emptied.each { |anchor, held| close(held, anchor, "shutdown") }
        nil
      end

      def [](anchor) = anchor && @monitor.synchronize { @held[anchor] }

      private

        def all = @monitor.synchronize { @held.values }

        def unavailable
          Daemon::Refusal.new(status: 422, code: "mcp_unavailable",
            message: "no extension serves an editor's MCP servers on this daemon: enable rho-mcp")
        end

        # The registrar's answer; the door's 400 for a list it refuses (its
        # ArgumentError), and the door's 503 `daemon_stopping` for a
        # registrar that will not open a set at all (its own
        # `Rho::Runner::Error`): the daemon does not know rho-mcp's classes,
        # and the one raiser the seam names is its shutdown ladder —
        # `Rho::Mcp::Closed` once it ran — so the refusal is the daemon's
        # own sentence and the registrar's rides the log line.
        def open(anchor, entries)
          @registrar.handler.call(anchor, entries)
        rescue ArgumentError => error
          @log&.warn("mcp_servers.malformed", anchor: anchor, detail: error.message)
          Daemon::Refusal.malformed(error.message)
        rescue Rho::Runner::Error => error
          @log&.warn("mcp_servers.registrar_closed", anchor: anchor, error_class: error.class.name, detail: error.message)
          Daemon::Refusal.stopping
        end

        # THE JUDGEMENT: every class keyed to its row FIRST (`SERVER_KEY`;
        # a class without one raises before anything is judged), then each
        # validated as `register_tool` validates it and tested against the
        # boot table and the other anchors; a taken name — or a class the
        # registry would refuse — faults its row and drops the row's
        # classes whole, the served entries being those whose row stands.
        def judge(anchor, set)
          keyed = Array(set.classes).map { |klass| [row_of(klass), klass] }
          entries = {}
          faults = {}
          keyed.each do |row, klass|
            entry = entry_over(klass)
            owner = taken_by(anchor, entry)
            next entries[entry.name] = [row, entry] if owner.nil?

            faults[row] = "name taken by #{owner}"
            @log&.warn("mcp_servers.name_taken", anchor: anchor, tool: entry.name, owner: owner, row: row)
          rescue Rho::Runner::Extensions::RegistrationError => error
            faults[row] = error.message
            @log&.warn("mcp_servers.class_refused", anchor: anchor, detail: error.message, row: row)
          end
          served = entries.reject { |_name, (row, _entry)| faults.key?(row) }.transform_values(&:last)
          [served.freeze, faults.freeze]
        end

        def entry_over(klass)
          extension = @registrar.extension
          Rho::Runner::Extensions::Tool.validate!(klass, extension: extension)
          Rho::Runner::Extensions::Registry::Entry.new(
            name: klass::NAME.to_s, klass: klass, extension: extension, source: "conversation", serves: :agent
          )
        end

        # The boot table first (settings.json's servers and rho's own tools
        # under any address), then another anchor's DIFFERENT entry.
        def taken_by(anchor, entry)
          served = @served.entries.find { |held| held.name == entry.name }
          return "the boot table (#{served.extension})" if served

          other = @monitor.synchronize do
            @held.find do |other_anchor, held|
              other_anchor != anchor && held.entries.key?(entry.name) && held.entries.fetch(entry.name).announcement != entry.announcement
            end
          end
          other && "conversation #{other.first}"
        end

        # The report row a class belongs to: its `SERVER_KEY` (the seam's
        # contract, `Extensions::Api#register_conversation_servers`). A
        # class without one is the registrar's bug, named — the public
        # name is folded and never parsed, so there is nothing to fall
        # back on.
        def row_of(klass)
          return klass::SERVER_KEY.to_s if klass.const_defined?(:SERVER_KEY, false)

          named = klass.const_defined?(:NAME, false) ? klass::NAME.to_s : klass.inspect
          raise Rho::Runner::Extensions::RegistrationError,
            "#{named} carries no SERVER_KEY: a conversation server's class names its row (#{@registrar.extension})"
        end

        def drop(anchor, reason:)
          removed = @monitor.synchronize do
            held = @held[anchor]
            next nil if held.nil?

            @held = @held.except(anchor).freeze
            held
          end
          return false if removed.nil?

          close(removed, anchor, reason)
          true
        end

        # A set that cannot close costs its own log line, never the drop.
        def close(held, anchor, reason)
          held.set.close
        rescue StandardError => error
          @log&.warn("mcp_servers.close_failed", anchor: anchor, error_class: error.class.name)
        ensure
          @log&.info("mcp_servers.closed", anchor: anchor, reason: reason, tools: held.entries.length)
        end
    end
  end
end
