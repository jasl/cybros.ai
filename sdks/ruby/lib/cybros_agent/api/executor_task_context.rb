module CybrosAgent
  module Api
    # ONE ROW OF THIS EXECUTOR'S INBOX: claim it, then commit its answer.
    #
    # THE CLAIM IS WHERE TWO PROCESSES OF ONE ADDRESS RACING FOR ONE ROW ARE
    # RESOLVED. The inbox is per executor and complete, so every process
    # holding this credential SEES the same work; exactly one may execute
    # it, and the claim mints the token that proves which. Exclusivity is
    # by TOKEN AND TIME, never by principal — the address proves the door,
    # the token proves the claim.
    #
    # A claim stands until the park's own deadline and there is no heartbeat
    # to send — a claimant still at work EXTENDS that one deadline (`extend`),
    # bounded and narrated, and a deadline it did not move stays the
    # deadline. Past it the sweep settles the row by the tool's effect
    # profile — `timed_out` for a replayable call, `uncertain` for a claimed
    # one whose effect may have escaped — and a claim is NEVER
    # re-granted; a dead token's commit is refused `stale_claim`
    # rather than overwriting the settled answer.
    class ExecutorTaskContext
      include AgentLoopProjections
      include Fields
      include UploadProjections

      attr_reader :agent_loop_public_id, :task_key

      def initialize(dispatch:, agent_loop_public_id:, task_key:)
        @dispatch = dispatch
        @agent_loop_public_id = required_string_snapshot(agent_loop_public_id, "agent_loop_public_id")
        @task_key = required_string_snapshot(task_key, "task_key")
      end

      # CLAIMING IS ALSO THE FETCH: a grant answers with the executable row —
      # `tool_input` and `tool_call_id` included — so a runner nudged with a
      # task key goes straight here and never lists at all. The list remains
      # the truth and the recovery path; it is not the only way in.
      def claim
        shape(ClaimedTask, @dispatch.call("#{path}/claim", method: :post))
      end

      # A read of this exact execution, including when its loop is paused and
      # no longer listed. The proof stays out of the URL and the returned value.
      def claim_status(claim_token:)
        headers = { "Claim-Token" => required_string(claim_token, "claim_token") }
        shape(ClaimStatus, @dispatch.call("#{path}/claim", headers: headers))
      end

      # Input bytes are available only while this exact claim is active.
      def attachment(public_id, claim_token:)
        headers = { "Claim-Token" => required_string(claim_token, "claim_token") }
        shape(Upload, @dispatch.call("#{path}/attachments/#{public_id}", headers: headers), "upload")
      end

      def attachment_bytes(public_id, io, claim_token:, range: nil)
        headers = { "Claim-Token" => required_string(claim_token, "claim_token") }
        headers["Range"] = range unless range.nil?
        response = @dispatch.download("#{path}/attachments/#{public_id}/bytes",
          headers: headers, sink: io, success: range.nil? ? 200 : 206)
        AttachmentRead.new(status: response.status, etag: response.etag)
      end

      # THE CLAIMANT'S EXTENSION (executor.md "Extend"): `timeout_ms` is the
      # new budget FROM NOW, bounded by the tool's announced park or the
      # kernel's hour; only the current claimant — this address AND its
      # token — may ask, as often as the work needs. Answers the claim's own
      # shape, `deadline_at` moved and the token unrotated; the refusals are
      # the door's typed conflicts (`not_claimant`, `not_extendable`,
      # `extension_too_long`), raised as `Api::Conflict`.
      def extend(claim_token:, timeout_ms:)
        fields = {
          "claim_token" => required_string(claim_token, "claim_token"),
          "timeout_ms" => positive_integer(timeout_ms, "timeout_ms"),
        }
        shape(ClaimedTask, @dispatch.call("#{path}/extend", method: :post, body: fields))
      end

      # THE TWO-AXIS ANSWER, and the distinction is the whole contract.
      #
      # `is_error` is DATA: the tool RAN and returned an error, and the model
      # reads that and self-corrects. `outcome` is CONTROL: "failed" says the
      # tool could not run at all, and takes the task's own failure policy —
      # which may cascade. A tool that errored is `outcome: "completed",
      # is_error: true`; collapsing the two loses the model's chance to fix
      # its own call.
      #
      # WRITE-ONCE: a second commit under the same token after the
      # settle answers 200 `idle` and changes nothing, so a runner retrying a
      # transport-refused commit while its deadline stands is safe.
      #
      # THE THREE CHANNELS (executor.md, "Commit"), one meaning each.
      #
      # `content` IS MCP's `CallToolResult.content` — a plain String, or a
      # list of content blocks of the TWO kinds the kernel carries: `text`
      # (`{"type" => "text", "text" => …}`) and `resource_link`
      # (`ResourceLink#to_h`: `uri` of the one scheme the kernel resolves,
      # `nexus://uploads/<public_id>`, `name` required) — and the ONLY
      # channel a model reads. THE CAPTURE RULE: a link names a capture
      # this executor staged FIRST through its own upload door, else the
      # commit is `422 unknown_result_upload`; any other kind is
      # `invalid_content`. A bare String stays valid forever and is
      # byte-identical to a single text block on the server, which matters
      # more than it looks: the tool-result entry is the prompt-cache
      # breakpoint.
      #
      # `structured_content` IS MCP's `structuredContent` — any JSON value.
      # It is stored whole and served back on the task read, where a
      # client or a UI picks it up, and it NEVER reaches the model: the
      # server serializes nothing into the text position, so a commit
      # carrying structure and no text hands the model `""`. A tool that
      # wants the model to read its structure puts the words in `content`
      # beside it.
      #
      # `metadata` is the model-invisible carrier — a JSON object served on
      # the task read, `checkpoint` its one reserved key — and `title` the
      # UI's one-line header for a collapsed row. Neither is ever shown to
      # the model.
      #
      # AN ASK'S COMMIT CARRIES NO TOKEN: an `ask` row is listed for its
      # addressee and never claimed, so the row names its answerer and that
      # is the door — `claim_token: nil` sends no field and the server reads
      # the address. A tool row still needs its token; a
      # non-string is the caller's bug and never leaves the process.
      def commit(claim_token:, content: UNSET, structured_content: UNSET,
                 result_type: UNSET, is_error: UNSET, outcome: UNSET,
                 title: UNSET, metadata: UNSET)
        body = fields(
          claim_token: claim_token.nil? ? UNSET : required_string(claim_token, "claim_token"),
          content:, structured_content:, result_type:, is_error:, outcome:, title:, metadata:
        )

        # FLAT, not wrapped. The door reads the envelope straight off the
        # request parameters, so a nesting key sends `claim_token` nowhere
        # and the settle refuses `stale_claim` — after the tool has already
        # run, which is the worst moment to discover it.
        @dispatch.call("#{path}/commit", method: :post, body: body)
      end

      private

        # A budget that is not a positive whole number of milliseconds is
        # the caller's bug and never leaves the process.
        def positive_integer(value, name)
          integer = Integer.try_convert(value)
          return integer if integer&.positive? && integer.eql?(value)

          raise ArgumentError, "#{name} must be a positive Integer of milliseconds"
        end

        def path
          "#{ExecutorClient::INBOX_PATH}" \
            "/#{path_segment(@agent_loop_public_id, "agent_loop_public_id")}" \
            "/#{path_segment(@task_key, "task_key")}"
        end
    end
  end
end
