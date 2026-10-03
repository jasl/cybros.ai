module Rho
  # Which hosts this machine follows, so a restart follows them again — the
  # kernel keeps running them, but followers are process state. ONE store,
  # host-keyed: a standalone loop Ops authored, or a conversation rho
  # opened. A CACHE under tmp/ (losing it costs a
  # follower, never the work), bounded, evictions reported. Policy fields
  # are only an in-memory projection of Nexus Store and never written here.
  class HostStore
    MAX_ROWS = 64
    # "Nothing said" for turn, loop, runner and answerer, where nil is a VALUE
    # (a manual answer has no backing loop): a call that passes
    # nothing keeps them, a call that passes nil clears them.
    KEEP = Object.new.freeze

    # `turn`/`loop` are the conversation host's correlation — its current
    # turn and that turn's backing loop, the id every loop-grain verb is
    # given; absent on a loop host, which is its own. `model` is what the
    # conversation last replied on, which `rho say` asks for again;
    # `compose` is the tier it was opened in (true, false, or nil when
    # nothing said one, which resolves through the ladder), which `rho say`
    # keeps — a conversation holds its tier for its whole life. `notes` is
    # the extensions' policy, reloaded from Nexus at re-adoption and keyed
    # by extension name. `runner` is the runner the host's
    # tool calls land on as this daemon last learned it — the create's
    # answer, a handoff it made, a `runner_bound` it followed;
    # nil is none bound. No row remembers whom the last lead was rendered
    # for: the lead rides every turn and the kernel lays it once per window
    # (only it knows the window), so there is nothing to compare against. `answerer` is the FOREIGN profile a
    # conversation is answered by (`rho do --agent`) — nil
    # when rho itself answers — so every later `rho say` sends that
    # conversation the bare words (no `tool_names`, no `approval_mode`, no
    # lead: those are rho's own declaration's, judged against the
    # addressee's).
    Row = Data.define(:host_type, :host_public_id, :workspace, :live, :remembered_at,
                      :turn, :loop, :model, :compose, :notes, :runner, :answerer) do
      def initialize(runner: nil, answerer: nil, **members) =
        super(runner: runner, answerer: answerer, **members)

      def foreign? = !answerer.nil?

      def self.from_h(hash)
        new(
          host_type: hash.fetch("host_type"), host_public_id: hash.fetch("host_public_id"),
          workspace: hash.fetch("workspace"), live: hash.fetch("live"),
          remembered_at: hash["remembered_at"].to_s, turn: hash["turn"], loop: hash["loop"],
          model: hash["model"], compose: hash["compose"], notes: Hash.try_convert(hash["notes"]) || {},
          runner: hash["runner"], answerer: hash["answerer"]
        )
      end

      def host = Host.from(host_type, host_public_id)

      def to_h
        { "host_type" => host_type, "host_public_id" => host_public_id, "workspace" => workspace,
          "live" => live, "remembered_at" => remembered_at, "turn" => turn, "loop" => loop,
          "model" => model, "compose" => compose, "notes" => notes, "runner" => runner,
          "answerer" => answerer }.compact
      end
    end

    def initialize(path, clock: -> { Time.now })
      @file = StateFile.new(path)
      @clock = clock
      @policies = {}
    end

    def rows
      document = Hash.try_convert(@file.read)
      return [] unless document

      Array(document["hosts"]).filter_map do |row|
        Row.from_h(row.merge(@policies.fetch([row.fetch("host_type"), row.fetch("host_public_id")], {}))) if Hash.try_convert(row)
      end
    end

    def project(host, policy)
      @policies[[host.type, host.public_id]] = policy ?
        { "model" => policy.model, "compose" => policy.compose, "notes" => policy.notes } : {}
      find(host.public_id)
    end

    # The row a verb's id names: the host's own id, or the backing loop
    # of a conversation this machine follows.
    def find(public_id)
      rows.find { |row| row.host_public_id == public_id || row.loop == public_id }
    end

    # One row per host, newest last: a later call is the current truth. A
    # call that says nothing about notes, the turn, the loop, the model or
    # the tier keeps them, so an attach or a detach cannot silently un-gate
    # a host, forget which loop is backing its turn, or lose an off tier
    # (`false` is a value here, so nil alone means "nothing said"; turn, loop and
    # the two binding fields say nothing through `KEEP`, because nil is their
    # "none").
    def remember(host, workspace:, live: true, notes: nil, turn: KEEP, loop: KEEP, model: nil, compose: nil,
                 runner: KEEP, answerer: KEEP)
      evicted = nil
      @file.with_lock do
        previous = rows.find { |row| row.host == host }
        kept = rows.reject { |row| row.host == host }
        kept << Row.new(
          host_type: host.type, host_public_id: host.public_id, workspace: workspace, live: live,
          remembered_at: @clock.call.iso8601, turn: turn.equal?(KEEP) ? previous&.turn : turn,
          loop: loop.equal?(KEEP) ? previous&.loop : loop,
          model: model || previous&.model, compose: compose.nil? ? previous&.compose : compose,
          notes: notes || previous&.notes || {},
          runner: runner.equal?(KEEP) ? previous&.runner : runner,
          answerer: answerer.equal?(KEEP) ? previous&.answerer : answerer
        )
        if kept.length > MAX_ROWS
          evicted = kept.first(kept.length - MAX_ROWS).map(&:host_public_id)
          kept = kept.last(MAX_ROWS)
        end
        @policies = kept.to_h { |row| [[row.host_type, row.host_public_id], row.to_h.slice("model", "compose", "notes")] }
        store(kept)
      end
      evicted
    end

    def forget(host)
      @file.with_lock do
        kept = rows.reject { |row| row.host == host }
        @policies.delete([host.type, host.public_id])
        kept.empty? ? @file.delete : store(kept)
      end
      self
    end

    private

      def store(kept)
        @file.write("hosts" => kept.map { |row| row.to_h.except("model", "compose", "notes") })
      end
  end
end
