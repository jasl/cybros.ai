require "securerandom"

module Rho
  class Runner
    module Tools
      # THE RESTORE: a relayed runner-surface call that puts the
      # root back to a tree the store holds unconditionally.
      # UNDO-FIRST: the tool itself captures the current tree
      # as a new checkpoint under THIS call's own loop before it touches a
      # file, so every restore is itself restorable and a restore that
      # cannot be undone is not performed. The answer's `undo` IS a
      # checkpoint on the reserved key (`metadata.checkpoint`), so a
      # reader finds it where it finds every checkpoint and `checkpoints
      # {run_public_id: <this loop>}` lists it.
      #
      # DESCRIBED TO NOBODY (the `files_bytes` posture): no
      # model rewinds its own world — `DESCRIPTION` is nil, the name is
      # announced schema-less and hidden by name on rho's side; a member
      # reaches it through a request loop (`rho rewind`, `rho call_tool R
      # checkpoint_restore`). A declaration that names it anyway restores under
      # its loop's approval mode. The kernel's approval stage sees an
      # ordinary destructive write-kind row.
      #
      # REFUSED WHOLE, never partially: a target with an entry under a
      # protected root (`restore_refused: protected_root_inside`), an
      # unknown tree (`checkpoint_unknown`), a runner with no store
      # (`checkpoints_disabled`), an undo that could not be captured
      # (`restore_refused`). A git failure AFTER the undo answers
      # `restore_failed` naming the undo — on the text, on the structure
      # and on the key — so the tree before the call is never lost.
      class CheckpointRestore
        NAME = "checkpoint_restore".freeze
        DESCRIPTION = nil
        EFFECT_PROFILE = {
          "kind" => "write", "destructive" => true, "effect_scope" => "closed",
          "idempotency" => "none", "reconciliation" => "none",
        }.freeze
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "checkpoint" => { "type" => "string", "description" => "The tree hash of a checkpoint in this runner's store" },
            "store" => { "type" => "string", "description" => "The checkpoint's store id; omitted selects the current root" },
          },
          "required" => ["checkpoint"],
          "additionalProperties" => false,
        })
        # The undo capture plus the read-tree, each under the store's clock.
        TIMEOUT_MS = 120_000
        DISABLED = "checkpoints_disabled: no store".freeze

        def initialize(env:)
          @env = env
        end

        def call(args)
          @env.raise_if_cancelled!
          store = args.key?("store") ? @env.checkpoint_stores(args.fetch("store")).first : @env.checkpoints
          return Result.error("checkpoint_store_unknown: #{args.fetch("store")}") if store.nil? && args.key?("store")
          return Result.error(DISABLED) if store.nil?

          outcome = store.restore(args.fetch("checkpoint"), undo_loop: undo_loop)
          case outcome
          in Runner::Checkpoints::Restored then restored(outcome)
          in Runner::Checkpoints::Refusal then refused(outcome)
          end
        rescue ArgumentError => error
          Result.error("invalid_arguments: #{error.message}")
        end

        private

          # The request loop's id — the undo is recorded under it; a call
          # outside a task (a probe) mints a local name.
          def undo_loop
            ExecutionContext.current&.run_public_id || "local-#{SecureRandom.hex(4)}"
          end

          def restored(outcome)
            structure = {
              "restored" => outcome.restored, "undo" => outcome.undo, "files" => outcome.files,
              "removed" => outcome.removed, "nested" => outcome.nested,
            }
            Result.ok(
              "Restored #{outcome.files} files to #{outcome.restored}" \
              "#{outcome.removed.positive? ? " (#{outcome.removed} removed)" : ""}; undo with #{outcome.undo}",
              structure, title: "world restored", metadata: checkpoint_key(outcome.record)
            )
          end

          def refused(refusal)
            return Result.error(refusal.message) if refusal.record.nil?

            Result.error(refusal.message, { "undo" => refusal.undo },
              metadata: checkpoint_key(refusal.record))
          end

          # THE UNDO IS A CHECKPOINT ON THE RESERVED KEY, spelled by the
          # record itself (`Record#key`) under the hook's one key name — an
          # undo captures the whole tree under no path-precise call, so
          # its key is `{hash, store}` by the record's own present-only
          # rule, never a second shape written here.
          def checkpoint_key(record) = { Extensions::Checkpoints::RESERVED_KEY => record.key }
      end
    end
  end
end
