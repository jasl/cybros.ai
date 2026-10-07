module AgentRuns
  module Parks
    # The one resolution engine for the resolve endpoint, the append
    # envelope and the timeout sweep. The deadline wins: a late resolution
    # settles by the expiry rule, and the SQL frontier is advisory to this
    # recheck under the lock. Expiry has ONE rule, for the sweep and for a
    # late answer alike: never claimed → `timed_out`; a replayable profile
    # → `timed_out`; otherwise `uncertain` — the effect may have escaped,
    # and only a person may re-run it. A row HELD for an approver is on the
    # same clock and has ONE door here: the timeout path, to `timed_out
    # approval_expired` (nothing started, so never `uncertain`); a person's
    # resolution on it is `task_not_running` — the member verbs decide it.
    class Settle
      # Measured before any lock is taken, against the registry's value:
      # two constants for one boundary is how the documented and enforced
      # bounds drift apart.
      RESULT_BOUND = :snapshot_bound
      OUTCOMES = %w[completed failed].freeze
      MAX_TITLE_LENGTH = 200
      # The two sentences a weak model acts on, through the envelope's
      # `error_key: error_detail`; bounded by the column's 256.
      UNCERTAIN_DETAIL = "the executor holding this call expired without a result; " \
        "its effect may have happened. Check before re-running.".freeze

      # The one failure the engine writes on a REFUSAL: a tool result
      # whose bytes can never be stored is a failed outcome, not an open
      # park to its claim deadline.
      UNSTORABLE = "result_unstorable".freeze

      # `moved` says the graph changed under this call — a settlement to
      # schedule. `applied`/`idle` are the door's 200; a refusal is not
      # applied, and one refusal (`failed`) still moved the graph: the
      # door answers 422 for the bytes while the park is closed behind it.
      Result = Data.define(:outcome, :node, :moved) do
        class << self
          def applied(node) = new(outcome: :applied, node: node, moved: true)
          def idle(node) = new(outcome: :idle, node: node, moved: false)
          def refused(code, node = nil) = new(outcome: code, node: node, moved: false)
          def failed(code, node) = new(outcome: code, node: node, moved: true)
        end

        def applied? = outcome == :applied
        def settled? = %i[applied idle].include?(outcome)
        def moved? = moved
      end

      def self.call(...) = new(...).call

      # A coupled kernel result already holds its loop and park. Defer graph
      # release until the caller has published every result and rewired reads.
      def self.settle_locked(node:, content:, outcome:, resolved_by: nil)
        new(node: node, content: content, outcome: outcome, resolved_by: resolved_by,
          trusted: true, release: false).settle_locked
      end

      # `trusted` is a kernel settle inside the authoring trust domain;
      # every outside settle presents the park's own bearer token.
      # `creator` is whose CAPTURES a `resource_link` may name: the
      # committing executor on the executor door, the acting user on the
      # person's resolution; nil (a kernel settle, the sweep) admits no
      # link at all.
      def initialize(node:, claim_token: nil, content: nil, outcome: nil,
                     timeout: false, trusted: false, is_error: false,
                     title: nil, metadata: nil, structured_content: nil,
                     structured_content_present: !structured_content.nil?,
                     result_type: nil, resolved_by: nil, creator: nil, release: true,
                     retained_upload_ids: nil)
        @node = node
        @claim_token = claim_token
        @creator = creator
        @retained_upload_ids = retained_upload_ids
        @release = release
        # WHO RESOLVED IT: `{kind, public_id}` on the settle's own narration
        # item — a spawned child on the relay's await path — never a column;
        # nil is the ordinary settle.
        @resolved_by = resolved_by
        # Both park doors reach the result grammar through here, so one
        # wire field cannot have two meanings.
        @parsed = ResultContent.call(
          content: content, structured_content: structured_content,
          structured_content_present: structured_content_present, result_type: result_type
        )
        @structured_content = structured_content
        @content_refusal = @parsed.refusal
        @outcome = outcome
        @timeout = timeout
        @trusted = trusted
        @is_error = is_error
        # The runner's UI-only channel (opencode's split): never spliced
        # into a model request.
        @title = title.to_s.presence&.first(MAX_TITLE_LENGTH)
        @metadata = metadata
        # Still a client payload: unbounded it uncaps the transcript page,
        # and a NUL would abort the settle at INSERT.
        @ui_refusal = ui_channel_refusal
        # Measured as storage measures it — canonical-JSON bytes of the
        # entry written, not the raw string.
        @oversized = !timeout && @content_refusal.nil? && oversized?
      end

      # Sizing never raises: unencodable content is unstorable, not too
      # large, and the storage guard answers that. The parent class, so no
      # subclass falls through.
      def oversized?
        !Nexus::SizeBounds.json_within?(RESULT_BOUND, @parsed.entries)
      rescue Nexus::CanonicalJson::UnsupportedValue
        false
      end

      def call
        agent_run = @node.agent_run
        # Loop before node, the ladder's order; both rows are in hand.
        result = agent_run.with_lock do
          # THE LINKED CAPTURES, resolved and pinned BETWEEN the two locks:
          # `content_uploads` sits below `agent_runs` and above
          # `agent_run_tasks` on the ladder (lock_order_guard_test).
          resolve_linked_uploads
          @node.lock!
          adjudicate(agent_run, @node)
        end
        ScheduleJob.perform_later(agent_run.id) if result.moved?
        result
      end

      def settle_locked
        resolve_linked_uploads
        adjudicate(@node.agent_run, @node)
      end

      private

        def adjudicate(agent_run, node)
          # A terminal loop or task settles nothing and refuses nothing:
          # the answer simply arrived after the question stopped mattering.
          return Result.idle(node) if agent_run.terminal? || node.terminal?
          # The token exists from creation, so completing an undispatched
          # await would release successors out of graph order. A held row
          # enters by the timeout path alone.
          return Result.refused(:task_not_running, node) unless node.started? || (@timeout && node.held?)
          return Result.refused(:stale_claim, node) unless
            @timeout || @trusted || claim_held?(node) || open_to_write_standing?(node)

          # External claims use the same database clock as operation admission.
          # Approval, kernel work and asks keep their owning virtual-clock path.
          now = agent_run.effective_now(DatabaseClock.now) if node.tool_call? && node.claimed_at.present?
          expired = node.deadline_passed?(now)
          # Only an actually-overdue park may be failed by the sweep. A
          # canceling loop still settles its parks, or the graceful drain wedges.
          return Result.idle(node) if @timeout && !expired
          # The park survives an oversized submission. Malformed is
          # refused before size: "too large" is a fact about storable bytes.
          return Result.refused(@content_refusal, node) if @content_refusal && !expired
          return Result.refused(:result_too_large, node) if @oversized && !expired
          return Result.refused(@ui_refusal, node) if @ui_refusal && !expired
          # A link that is not the committer's own capture: the input
          # door's `unknown_input_upload` twin, the park standing.
          return Result.refused(@link_refusal, node) if @link_refusal && !expired

          settle(agent_run, node, expired)
        end

        # The committer's OWN captures, `FOR KEY SHARE` under the loop lock
        # so the orphan reaper cannot take one between this read and the
        # bind (`ContentUploads::ResolveReferences`, the input doors' own
        # class and lock). Nobody's — no creator — refuses every link.
        def resolve_linked_uploads
          @linked_uploads = []
          @link_refusal = nil
          ids = @parsed.upload_public_ids
          return if ids.empty?
          return @link_refusal = ContentUploads::ResolveReferences::RESULT_REFUSAL if @creator.nil?

          resolved = ContentUploads::ResolveReferences.call(
            account: @node.account, creator: @creator, public_ids: ids, lock: true,
            retained_upload_ids: @retained_upload_ids
          )
          if resolved.accepted?
            @linked_uploads = resolved.uploads
          else
            @link_refusal = ContentUploads::ResolveReferences::RESULT_REFUSAL
          end
        end

        # `error_detail` is a column an adjudicator reads, so it takes the
        # text the model would see, never a serialized entry.
        def rejection_words = readable_text.presence

        # Each park names its failures in the vocabulary its holder
        # speaks: a rendezvous nobody kept, or a tool call that ran long
        # or could not run at all — the type's own `park_kind`.
        def timeout_key(node) = "#{node.park_kind}_timeout"

        # A held row expired with nobody deciding: `approval_expired`, before
        # the uncertain test — nothing was dispatched, nothing was claimed
        # (`claimed_at` is nil on a held row; pinned explicitly here).
        APPROVAL_EXPIRED = "approval_expired".freeze

        def expiry(node)
          return { status: "timed_out", error_key: APPROVAL_EXPIRED } if node.held?
          return { status: "timed_out", error_key: timeout_key(node) } unless expiry_uncertain?(node)

          { status: "uncertain", error_key: "tool_uncertain", error_detail: UNCERTAIN_DETAIL }
        end

        # Never claimed (an await, a kernel row, a row nobody took) →
        # nothing started; a replayable profile → a re-run is harmless;
        # else the effect may have escaped and only a person may re-run
        # it. The runner clamps and COMMITS its own timeouts, so this arm
        # is reserved for a claim nobody answered.
        def expiry_uncertain?(node)
          node.tool_call? && node.claimed_at.present? && !node.replayable?
        end

        def failure_key(node) = "#{node.park_kind}_failed"

        # Bounded and STORABLE, on the registry every other client JSON
        # on this plane goes through. Returns the typed refusal, or nil.
        def ui_channel_refusal
          return :invalid_title if @title&.include?("\u0000")
          return nil if @metadata.nil?
          return :invalid_metadata unless Hash.try_convert(@metadata)

          unless Nexus::SizeBounds.json_within?(:envelope_bound, @metadata)
            return :metadata_too_large
          end

          nil
        rescue Nexus::CanonicalJson::UnsupportedText,
               Nexus::CanonicalJson::UnsupportedNumber
          :invalid_metadata
        end

        # A kernel-authored await issues no token, so write standing on the
        # workspace authorizes the answer. Typed to the await by the row
        # itself: a tool task's token is absent before a claim, and "no
        # token" would let anyone steal its result.
        def open_to_write_standing?(node) = node.asking?

        def claim_held?(node)
          token = node.settlement_claim_token
          token.present? && @claim_token.present? &&
            ActiveSupport::SecurityUtils.secure_compare(token, @claim_token.to_s)
        end

        # Content lands first because storing it can still refuse; the
        # charge rides the terminal write. A refused AWAIT answer leaves the
        # park running, uncharged and retryable — its resolver is a person
        # at an interactive door. A refused TOOL result closes the park
        # FAILED: the runner's report is final (a typed refusal is never
        # resubmitted), so an open park would only wait out its deadline for
        # a failure the model can read now.
        def settle(agent_run, node, expired)
          refusal = expired ? nil : attach_refusal(node)
          if refusal
            return Result.refused(:result_unstorable, node) unless node.tool_call?

            fail_node(agent_run, node, status: "failed", error_key: UNSTORABLE,
              error_detail: unstorable_detail(refusal))
            return Result.failed(:result_unstorable, node)
          end
          StampOutputPreview.call(node) unless expired
          node.capture_runner_checkpoint(metadata: @metadata) unless expired

          if expired
            fail_node(agent_run, node, **expiry(node))
          elsif @outcome == "failed"
            # An adjudicator deciding retry vs abandon has nothing else to
            # read: the body carries the words, the error detail their first line.
            fail_node(agent_run, node, status: "failed", error_key: failure_key(node),
              error_detail: rejection_words)
          elsif (hook_refusal = LifecycleHooks.result_refusal(node, @structured_content, is_error: @is_error))
            fail_node(agent_run, node, status: "failed", error_key: hook_refusal.to_s,
              error_detail: "The lifecycle hook did not return an accepted decision.")
          else
            complete_node(agent_run, node)
          end
          Result.applied(node)
        end

        # `is_error` is data and the outcome is control: a tool that ran and errored
        # completed.
        def complete_node(agent_run, node)
          Transition.node(
            node,
            narration: narration,
            **{ status: "completed", completed_at: Time.current,
                output_summary: { "resolved" => true, "is_error" => @is_error }.compact_blank,
                result_title: @title, result_metadata: @metadata }.compact
          )
          if @release
            Release.settled(node)
            EvaluateQuiescence.call(agent_run.reload)
          end
        end

        def fail_node(agent_run, node, status:, error_key:, error_detail: nil)
          TaskOperations.cancel_attached_locked(node) if node.operation_owner?
          worklist = []
          FailNode.call(agent_run: agent_run, node: node, worklist: worklist,
            status: status, error_key: error_key, error_detail: error_detail, narration: narration,
            release: @release)
          EvaluateQuiescence.call(agent_run.reload) if @release
        end

        def narration = ({ "resolved_by" => @resolved_by } if @resolved_by)

        # The storage guard's typed word, or nil once the content landed: a
        # bare `ActiveRecord::Rollback` would be swallowed, since this
        # service joins its caller's transaction.
        #
        # `readable_text` is THE WRITER'S WORD (the
        # "picture alone" precedent): the text blocks joined, `""` when the
        # result carries structure and no text — so `effective_text` answers
        # what the model reads and never falls back to the entry JSON of a
        # `structured` entry. `structured_content` is the UI's channel and
        # is never rendered to a model. `uploads:` BINDS the linked captures:
        # the capture lives as long as the result
        # does (the RESTRICT FK), and the reaper cannot take it under a reader.
        def attach_refusal(node)
          return nil if @parsed.empty?

          ContentBodies::Replace.call(
            owner: node, role: "output", entries: @parsed.entries, seal: true,
            readable_text: readable_text, uploads: @linked_uploads
          ).refusal
        end

        def readable_text
          @parsed.entries.filter_map { |entry| entry[ResultContent::TEXT] }.join("\n")
        end

        # What the model reads through the envelope's `(key) detail`: the
        # guard's own word, so the trace says what the door said.
        def unstorable_detail(refusal) = "#{refusal}: the result's bytes cannot be stored"
    end
  end
end
