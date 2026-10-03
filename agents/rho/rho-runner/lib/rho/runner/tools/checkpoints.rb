module Rho
  class Runner
    module Tools
      # THE STORE'S READ: the records this runner holds for its
      # root, one record with its changes against NOW, or the changes
      # between two trees — the truth the kernel's `metadata.checkpoint`
      # is a cache of (K-s3), and, with `files_bytes`, the console's diff
      # producer.
      #
      # FOUR SHAPES, ONE TOOL: `{}` or `{loop}` lists the records
      # (`structured_content: {records: [...]}`, each with `present`);
      # `{checkpoint}` answers that record plus `changed` = the tree vs
      # the root as it is now (a whole-tree stage under the capture's caps and clock — `checkpoint_skipped {reason}` on overrun);
      # `{from, to}` answers `changed` between two trees with NO work-tree
      # pass — the per-turn diff (turn N's changes = N's tree → N+1's).
      #
      # DESCRIBED TO NOBODY: a read for a person and the SDK's cache miss,
      # never a model's; the schema stands for the run's validation.
      class Checkpoints
        NAME = "checkpoints".freeze
        DESCRIPTION = nil
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "store" => { "type" => "string", "description" => "Select one checkpoint store by its id" },
            "loop" => { "type" => "string", "description" => "List the records of one loop" },
            "checkpoint" => { "type" => "string", "description" => "One record, with its changes against the root now" },
            "from" => { "type" => "string", "description" => "The older tree of a diff" },
            "to" => { "type" => "string", "description" => "The newer tree of a diff" },
          },
          "additionalProperties" => false,
        })
        DISABLED = "checkpoints_disabled: no store".freeze
        SHAPES = "checkpoints takes {}, {loop}, {checkpoint} or {from, to}".freeze

        def initialize(env:)
          @env = env
        end

        def call(args)
          @env.raise_if_cancelled!
          keys = args.keys & %w[loop checkpoint from to]
          list = keys.empty? || keys == ["loop"]
          stores = if list || args.key?("store")
            @env.checkpoint_stores(args["store"])
          else
            [@env.checkpoints].compact
          end
          return Result.error("checkpoint_store_unknown: #{args.fetch("store")}") if stores.empty? && args.key?("store")
          return Result.error(DISABLED) if stores.empty?

          store = args.key?("store") ? stores.first : @env.checkpoints
          case keys.sort
          when [], ["loop"] then list(stores, args["loop"])
          when ["checkpoint"] then store ? one(store, args.fetch("checkpoint")) : Result.error(DISABLED)
          when %w[from to] then store ? between(store, args.fetch("from"), args.fetch("to")) : Result.error(DISABLED)
          else Result.error("invalid_arguments: #{SHAPES}")
          end
        rescue ArgumentError => error
          Result.error("invalid_arguments: #{error.message}")
        end

        private

          def list(stores, loop)
            records = stores.flat_map { |store| store.records(loop: loop) }
            lines = records.map { |record| "#{record.loop}  #{record.hash}  #{record.captured_at}  #{record.files} files" }
            Result.ok(records.empty? ? "No checkpoints." : lines.join("\n"),
              { "records" => records.map(&:to_row) }, title: "checkpoints")
          end

          def one(store, hash)
            record = store.records.find { |candidate| candidate.hash == hash }
            return Result.error("checkpoint_unknown: #{hash}") if record.nil? || !store.tree?(hash)

            changed = store.changed_since(hash)
            return Result.error("checkpoint_skipped: #{changed.reason}") if changed in Runner::Checkpoints::Skip

            Result.ok("#{record.loop}  #{hash}  #{record.captured_at}  #{record.files} files\n#{render(changed)}",
              { "record" => record.to_row, "changed" => changed }, title: "checkpoint #{hash[0, 12]}")
          end

          def between(store, from, to)
            [from, to].each { |hash| return Result.error("checkpoint_unknown: #{hash}") unless store.tree?(hash) }

            changed = store.changed(from: from, to: to)
            Result.ok(render(changed), { "changed" => changed }, title: "checkpoint diff")
          end

          def render(changed)
            return "No changes." if changed.empty?

            changed.map { |row| "#{row.fetch("status")}  #{row.fetch("path")}" }.join("\n")
          end
      end
    end
  end
end
