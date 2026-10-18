require "json"

module Rho
  class Runner
    module Checkpoints
      # The record and the complete manifest it names commit together.
      # Equal trees share a hash; each run's first capture and each restore's
      # undo retain their own record. The kernel keeps only Record#key as
      # metadata; the Runner remains the authority for bytes and retention.
      # The skip reasons a loop's next write does NOT retry: a cap is a
      # setting, not a transient.
      FINAL_SKIPS = %w[tree_too_large].freeze

      Record = Data.define(:run_public_id, :hash, :store, :root, :captured_at, :files, :skipped, :nested, :outside,
        :ignored, :present) do
        class << self
          # SQLite stores only this owner's JSON, written in the same transaction
          # as its manifest. Decode it once; internal readers trust the record.
          def parse(message, present: true)
            new(**JSON.parse(message.to_s).to_h.transform_keys(&:to_sym), present: present)
          end
        end


        def initialize(run_public_id:, hash:, store:, root:, captured_at:, files:, skipped:, nested:,
                       outside:, ignored:, present: true)
          super(run_public_id: run_public_id.to_s, hash: hash.to_s, store: store.to_s, root: root.to_s, captured_at: captured_at.to_s,
            files: Integer(files), skipped: Array(skipped).map(&:to_s).freeze,
            nested: Array(nested).map(&:to_s).freeze, outside: Array(outside).map(&:to_s).freeze,
            ignored: Array(ignored).map(&:to_s).freeze, present: present ? true : false)
        end

        def skip? = false

        # The persisted record, `present` excluded (it is a fact
        # about the store NOW, not about the capture).
        def message = JSON.generate(to_h.except(:present).transform_keys(&:to_s))

        # The reserved key's value.
        def key
          value = { "hash" => hash, "store" => store }
          value["outside"] = outside unless outside.empty?
          value["ignored"] = ignored unless ignored.empty?
          value
        end

        # The `checkpoints` read's row: the record plus `present`.
        def to_row = to_h.transform_keys(&:to_s)
      end

      # A capture that did not happen, and why: `tree_too_large` (final —
      # the caps are settings, not a transient), `timeout`, `checkpoint_failed`.
      Skip = Data.define(:reason, :bytes, :files, :detail) do
        def initialize(reason:, bytes: 0, files: 0, detail: nil)
          super(reason: reason.to_s, bytes: Integer(bytes), files: Integer(files), detail: detail&.to_s)
        end

        def skip? = true
        def final? = FINAL_SKIPS.include?(reason)

        def key = { "skipped" => reason, "bytes" => bytes, "files" => files }
      end

      # A restore that happened: the tree asked for, the undo RECORD the
      # tool captured first (its `key` is what rides the reserved key — the
      # one spelling; `undo` is its tree), and what the one primitive wrote
      # and removed.
      Restored = Data.define(:restored, :record, :files, :removed, :nested) do
        def undo = record.hash
      end

      # A restore that did not: `checkpoint_unknown`, `restore_refused` (a
      # protected root inside the tree; the undo could not be captured),
      # `restore_failed` (a failure after the undo — `record` is the undo
      # captured before the call, `undo` its tree).
      Refusal = Data.define(:code, :detail, :record) do
        def initialize(code:, detail:, record: nil)
          super(code: code.to_s, detail: detail.to_s, record: record)
        end

        def undo = record&.hash

        def message = "#{code}: #{detail}"
      end
    end
  end
end
