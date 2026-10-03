module AgentLoops
  module Memory
    # The six memory verbs, one class because they share the anchor
    # resolution, the refusal form and the settle — and the kernel-row
    # branch of the `skill` load, which IS `read` in anchor order. Every
    # failure is an error envelope the model reads, never a dead task.
    class Run
      MAX_READ_LINES = 2_000

      class << self
        def call(node:)
          new(node).call
        end
      end

      def initialize(node)
        @node = node
        @loop = node.agent_loop
        @input = node.tool_input
      end

      def call
        verb = Nexus::ToolRegistry.resolve(@node.tool_name)
        handler = HANDLERS[verb]
        return refuse(:memory_unknown_verb, @node.tool_name.to_s) if handler.nil?

        public_send(handler)
      rescue StandardError => error
        # A refused repair must not take the round with it. The model gets
        # a legible error and the loop keeps its shape.
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "memory_tool_failed", loop: @loop.public_id, task: @node.node_key })
        refuse(:memory_unavailable, error.class.name)
      end

      HANDLERS = {
        "nexus.memory.read" => :read,
        "nexus.memory.write" => :write,
        "nexus.memory.edit" => :edit,
        "nexus.memory.ls" => :ls,
        "nexus.memory.grep" => :grep,
        "nexus.memory.delete" => :delete,
        "nexus.skill.load" => :skill,
      }.freeze

      def read
        anchor = resolve or return
        document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
        return refuse(:memory_not_found, anchor.name) if document.nil?

        settle(slice(document.content), title: "read #{@input["path"]}")
      end

      def write
        anchor = resolve(authoring: true) or return
        revising(anchor) do |conversation|
          result = MemoryDocuments::Write.call(anchor: anchor, content: @input["content"], expected: nil,
            revises: conversation)
          next refuse(result.outcome, anchor.name) unless result.written?

          settle("Wrote #{@input["path"]} (#{result.document.bytesize} bytes).",
            title: "wrote #{@input["path"]}")
        end
      end

      # Match exactly one passage in the current document under the anchor
      # lock. Unrelated edits survive; an absent or ambiguous passage refuses.
      def edit
        anchor = resolve(authoring: true) or return
        revising(anchor) do |conversation|
          result = MemoryDocuments::Edit.call(anchor: anchor, old_text: @input["old_text"],
            new_text: @input["new_text"], expected: nil, revises: conversation)
          next refuse(result.outcome, anchor.name) unless result.written?

          settle("Edited #{@input["path"]}.", title: "edited #{@input["path"]}")
        end
      end

      def ls
        path = listing_path
        return if path.nil?

        entries = memory_context.listing(path: path)
        return settle("No memory documents.", title: "memory is empty") if entries.empty?

        settle(entries.map do |entry|
          "#{entry.path}  #{entry.bytesize} bytes  #{entry.written_at.iso8601}"
        end.join("\n"), title: "#{entries.length} memory documents")
      end

      def grep
        path = listing_path
        return if path.nil?

        found = memory_context.search(
          pattern: @input["pattern"], path: path,
          ignore_case: @input["ignore_case"] == true, limit: @input["limit"]
        )
        return refuse(found.refusal, String.try_convert(@input["pattern"]).to_s.first(80)) unless
          found.found?
        return settle("No matches found.", title: "no matches") if found.matches.empty?

        settle(matches_text(found), title: "#{found.matches.length} matches")
      end

      # THE KERNEL-ROW LOAD: literally `read` in anchor order —
      # `workspace/skills/<name>` then `user/skills/<name>` through the
      # anchor, the kernel-row precedence being that order — answering
      # exactly what `read` answers. A name in neither rung is the ONE error
      # word `skill_unknown` (a name that moved source since the turn's
      # block is the next turn's fact; the load finds it where it is now or
      # refuses — never a stale copy); a malformed name matches no row and
      # lands on the same word without a query.
      def skill
        name = String.try_convert(@input["name"]).to_s
        document = skill_document(name)
        return refuse(:skill_unknown, name.first(120), title: "skill refused") if document.nil?

        settle(slice(document.content), title: "read #{document.path}")
      end

      def delete
        anchor = resolve(authoring: true) or return
        revising(anchor) do |conversation|
          result = MemoryDocuments::Delete.call(anchor: anchor, expected: nil, revises: conversation)
          next refuse(result.outcome, anchor.name) unless result.deleted?

          settle("Deleted #{@input["path"]}.", title: "deleted")
        end
      end

      private

        # The conversation rung reaches a loop-backed loop through the seam;
        # a standalone loop has none, so `conversation/...` refuses here
        # rather than anywhere deeper. The user rung is the loop's
        # controlling Human's — nil for the system user, refused the same
        # way. Answers nil after settling, so each verb can `or return`. AN
        # AGENT NEVER AUTHORS ITS OWN INSTRUCTIONS : the three writing verbs
        # refuse a `skills/` path `memory_reserved_prefix` before the anchor
        # resolves — a person or their program writes a skill row through
        # the doors; `read`, `ls` and `grep` see it as any document.
        def resolve(authoring: false)
          if authoring && Nexus::Skills.reserved?(Scopes::Anchor.split(@input["path"]).last)
            refuse(:memory_reserved_prefix, String.try_convert(@input["path"]).to_s.first(120))
            return nil
          end

          anchor = memory_context.resolve(@input["path"], authoring: authoring)
          return anchor if anchor.resolved?

          refuse(anchor.refusal, String.try_convert(@input["path"]).to_s.first(120))
          nil
        end

        # The Human this turn answers to: the loop's creating principal's
        # steward for an agent, itself for a Human — the child agent's on a
        # spawned conversation (`AgentLoop#memory_principal`). Frozen per
        # loop, like `creating_user` is.
        def principal_human
          return @principal_human if defined?(@principal_human)

          @principal_human = @loop.memory_principal.controlling_human
        end

        # THE ANCHOR ROW FIRST, in ladder order (users and workspaces rank
        # above conversations, `lock_order_guard_test.rb`), then the
        # conversation for the fence — a loop-backed loop writes FOR its
        # conversation, and the member door holds the same two in the same
        # order, so the two doors never cross. For `conversation/` both are
        # one row, locked once. `Write` and `Delete` lock nothing: this
        # is the anchor's lock site, and the cap count's serialization.
        # The loop comes next: stop and duplicate jobs arbitrate on that
        # row, and the memory mutation and task result commit together.
        def revising(anchor, &block)
          conversation = @loop.conversation
          memory_context.with_locks(anchor) { executing { block.call(conversation) } }
        end

        def memory_context
          @memory_context ||= MemoryDocuments::Context.new(workspace: @loop.workspace,
            conversation: @loop.conversation, principal: @loop.creating_user, configuration: @loop.memory_context)
        end

        def executing
          @loop.with_lock do
            @node.reload
            next :idle if @loop.terminal? || @node.status != "running"
            if @node.deadline_passed?
              next Parks::Settle.call(node: @node, timeout: true).outcome
            end

            yield
          end
        end

        # `ls` and `grep` take a PREFIX rather than a path, so the scope
        # may be a bare `workspace/` or absent entirely. An empty path
        # answers the UNION of the scopes this loop can see; the user rung
        # of that union is the loop's controlling Human's ONLY — a foreign
        # steward's `user/` rows never appear.
        def listing_path
          raw = @input["path"].to_s
          return raw if raw.empty?

          anchor = memory_context.resolve(raw.include?("/") && !raw.end_with?("/") ? raw : "#{raw.delete_suffix("/")}/x")
          return raw if anchor.resolved?

          refuse(anchor.refusal, raw.first(120))
          nil
        end

        def matches_text(found)
          lines = found.matches.map do |match|
            "#{match.path}:#{match.line_number}: #{match.text}"
          end
          if found.truncated
            lines << "[Result limit reached. Narrow the pattern or raise limit=.]"
          end
          lines.join("\n")
        end

        def slice(content)
          offset = Integer(@input["offset"], exception: false)
          limit = Integer(@input["limit"], exception: false) || MAX_READ_LINES
          lines = content.each_line.to_a
          lines = lines.drop((offset - 1).clamp(0..)) if offset
          shown = lines.take(limit.clamp(..MAX_READ_LINES))
          text = shown.join
          return text if shown.length == lines.length

          "#{text}\n[Showing #{shown.length} of #{lines.length} lines. " \
            "Continue with offset=#{(offset || 1) + shown.length}.]"
        end

        # The two kernel rungs a skill may live on, in precedence order; a
        # rung whose row is absent (a nil controlling Human's `user/`) is
        # skipped as `resolve` would refuse it.
        def skill_document(name)
          return nil unless Nexus::Skills.skill_name?(name)

          %w[workspace user].each do |scope|
            anchor = Scopes::Anchor.call(path: "#{scope}/#{Nexus::Skills::PREFIX}#{name}",
              workspace: @loop.workspace, user: principal_human)
            next unless anchor.resolved?

            document = anchor.documents.eager_load(:memory_document_version).find_by(name: anchor.name)
            return document if document
          end
          nil
        end

        def refuse(code, detail = nil, title: "memory refused")
          settle([code, detail].compact.join(": "), is_error: true, title: title)
        end

        # The kernel settles its own tool: no claim token exists, because
        # the work was never handed out.
        def settle(text, is_error: false, title: nil)
          Parks::Settle.call(
            node: @node, trusted: true, outcome: "completed",
            content: text, is_error: is_error, title: title
          ).outcome
        end
    end
  end
end
