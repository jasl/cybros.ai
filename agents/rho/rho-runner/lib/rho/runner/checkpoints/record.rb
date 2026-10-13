require "json"

module Rho
  class Runner
    module Checkpoints
      # WHAT A CAPTURE LEAVES BEHIND, and the two shapes it answers.
      #
      # THE RECORD IS THE REF'S OBJECT: a capture ends
      # in one parentless commit whose MESSAGE is this record as JSON, and
      # one create-only ref `refs/checkpoints/<loop>` pointing at it — so
      # the record is atomic with the tree it names, `gc`-safe (the ref
      # keeps the tree), and readable with `cat-file -p`. `hash` is the
      # TREE (content-addressed: equal trees answer equal hashes, the dedup
      # pin); the ref is found by loop. `store` is the store's own id.
      #
      # `Record#key` is the reserved `metadata.checkpoint` value — `{hash,
      # store}` with `outside` and `ignored` present-only: the
      # paths a path-precise call named that the tree cannot hold, so a
      # rewind says what it did not restore. NO `runner` in the key (K-s1):
      # the kernel already holds the claimant. `Skip#key` is the other
      # shape, `{skipped, bytes, files}`; a size cap is FINAL (the loop's
      # next write does not retry it), a timeout or a git failure is not.
      # The record's fields on the wire, in the message's order.
      RECORD_FIELDS = %w[run_public_id hash store root captured_at files skipped nested outside ignored].freeze
      # The skip reasons a loop's next write does NOT retry: a cap is a
      # setting, not a transient.
      FINAL_SKIPS = %w[tree_too_large].freeze

      Record = Data.define(:run_public_id, :hash, :store, :root, :captured_at, :files, :skipped, :nested, :outside,
        :ignored, :present) do
        def initialize(run_public_id:, hash:, store:, root:, captured_at:, files:, skipped:, nested:,
                       outside:, ignored:, present: true)
          super(run_public_id: run_public_id.to_s, hash: hash.to_s, store: store.to_s, root: root.to_s, captured_at: captured_at.to_s,
            files: Integer(files), skipped: Array(skipped).map(&:to_s).freeze,
            nested: Array(nested).map(&:to_s).freeze, outside: Array(outside).map(&:to_s).freeze,
            ignored: Array(ignored).map(&:to_s).freeze, present: present ? true : false)
        end

        class << self
          # The record read back off a commit's message; a message that
          # is not this record's JSON answers nil (a foreign ref under the
          # prefix is nobody's record).
          def parse(message, present: true)
            parsed = JSON.parse(message.to_s)
            return nil unless parsed.is_a?(Hash) && parsed["hash"].is_a?(String) && parsed["run_public_id"].is_a?(String)

            new(**parsed.slice(*RECORD_FIELDS).transform_keys(&:to_sym), present: present)
          rescue JSON::ParserError, ArgumentError, TypeError
            nil
          end
        end

        def skip? = false

        # The commit message: the record, `present` excluded (it is a fact
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
      # the caps are settings, not a transient), `timeout`, `git_failed`.
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
      # `restore_failed` (git failed AFTER the undo — `record` is the undo
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
