module Rho
  # Which hosts this machine follows, so a restart follows them again — the
  # kernel keeps running them, but followers are process state. ONE store,
  # host-keyed: a standalone run Ops authored, or a conversation rho
  # opened. A CACHE under tmp/ (losing it costs a
  # follower, never the work), bounded, evictions reported. Policy fields
  # are only an in-memory projection of Nexus Store and never written here.
  class HostStore
    MAX_ROWS = 64
    # "Nothing said" for turn, run, runner and answerer, where nil is a VALUE
    # (a manual answer has no backing run): a call that passes
    # nothing keeps them, a call that passes nil clears them.
    KEEP = Object.new.freeze

    # `turn`/`run_public_id` are the conversation host's correlation — its current
    # turn and that turn's backing run, the id every run-grain verb is
    # given; absent on a run host, which is its own. `model` is what the
    # conversation last replied on, which `rho say` asks for again.
    # `notes` is the extensions' policy, reloaded from Nexus at re-adoption and keyed
    # by extension name. `runner` is the runner the host's
    # tool calls land on as this daemon last learned it — the create's
    # answer, a default Runner selection, a `default_runner_changed` it followed;
    # nil is none bound. No row remembers whom the last lead was rendered
    # for: the lead rides every turn and the kernel lays it once per window
    # (only it knows the window), so there is nothing to compare against. `answerer` is the FOREIGN profile a
    # conversation is answered by (`rho do --agent`) — nil
    # when rho itself answers — so every later `rho say` sends that
    # conversation the bare words (no `tool_names`, no `approval_mode`, no
    # lead: those are rho's own declaration's, judged against the
    # addressee's).
    Row = Data.define(:host_type, :host_public_id, :workspace, :live, :remembered_at,
                      :turn, :run_public_id, :model, :notes, :runner, :answerer, :code_mode) do
      def initialize(runner: nil, answerer: nil, code_mode: nil, **members) =
        super(runner: runner, answerer: answerer, code_mode: code_mode, **members)

      def foreign? = !answerer.nil?

      def self.from_h(hash)
        new(
          host_type: hash.fetch("host_type"), host_public_id: hash.fetch("host_public_id"),
          workspace: hash.fetch("workspace"), live: hash.fetch("live"),
          remembered_at: hash["remembered_at"].to_s, turn: hash["turn"], run_public_id: hash["run_public_id"],
          model: hash["model"], notes: Hash.try_convert(hash["notes"]) || {},
          runner: hash["runner"], answerer: hash["answerer"], code_mode: hash["code_mode"]
        )
      end

      def host = Host.from(host_type, host_public_id)

      def to_h
        { "host_type" => host_type, "host_public_id" => host_public_id, "workspace" => workspace,
          "live" => live, "remembered_at" => remembered_at, "turn" => turn, "run_public_id" => run_public_id,
          "model" => model, "notes" => notes, "runner" => runner,
          "answerer" => answerer, "code_mode" => code_mode }.compact
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
        { "model" => policy.model, "notes" => policy.notes, "code_mode" => policy.code_mode } : {}
      find(host.public_id)
    end

    # The row a verb's id names: the host's own id, or the backing run
    # of a conversation this machine follows.
    def find(public_id)
      rows.find { |row| row.host_public_id == public_id || row.run_public_id == public_id }
    end

    # One row per host, newest last: a later call is the current truth. A
    # call that says nothing about notes, the turn, the run or the model
    # keeps them, so attaching or detaching cannot forget the active turn.
    # Turn, run and the two binding fields say nothing through `KEEP`,
    # because nil is their "none".
    def remember(host, workspace:, live: true, notes: nil, turn: KEEP, run_public_id: KEEP, model: nil,
                 runner: KEEP, answerer: KEEP, code_mode: KEEP)
      evicted = nil
      @file.with_lock do
        previous = rows.find { |row| row.host == host }
        kept = rows.reject { |row| row.host == host }
        kept << Row.new(
          host_type: host.type, host_public_id: host.public_id, workspace: workspace, live: live,
          remembered_at: @clock.call.iso8601, turn: turn.equal?(KEEP) ? previous&.turn : turn,
          run_public_id: run_public_id.equal?(KEEP) ? previous&.run_public_id : run_public_id,
          model: model || previous&.model,
          notes: notes || previous&.notes || {},
          code_mode: code_mode.equal?(KEEP) ? previous&.code_mode : code_mode,
          runner: runner.equal?(KEEP) ? previous&.runner : runner,
          answerer: answerer.equal?(KEEP) ? previous&.answerer : answerer
        )
        if kept.length > MAX_ROWS
          evicted = kept.first(kept.length - MAX_ROWS).map(&:host_public_id)
          kept = kept.last(MAX_ROWS)
        end
        @policies = kept.to_h { |row| [[row.host_type, row.host_public_id], row.to_h.slice("model", "notes", "code_mode")] }
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
        @file.write("hosts" => kept.map { |row| row.to_h.except("model", "notes", "code_mode") })
      end
  end
end
