module AgentLoops
  # ONE renderer for a delivered tip: the bytes a model reads
  # when work it started answers — as a paired result for a blocking `task`,
  # as a user message for everything else the round reads, and as the mail
  # body when the answer outlives its turn. Never a stored field.
  #
  #   <task_result task="r3t1" status="completed">
  #   <prompt>…the first 80 characters…</prompt>
  #   …the tip's text…
  #   </task_result>
  #
  # A tool's tip names its CALL where a model's names its brief —
  # `<call>bash {"command":"bin/probe bravo"}</call>`, the name the model
  # called and the head of the stored input (`ToolTask#call_head`) — on
  # every read, one across a stage's boundary included: the brief is the
  # producer's context, which a stage's result boundary keeps, while the
  # call is what the result is OF, and the only identity a tip a script
  # placed has, since its key is an id no model saw. So a read across that
  # boundary names the tip's own key and no brief; every other model
  # result a step reads carries its root's brief and key, which is how two
  # results handed to one step are told apart.
  #
  # An ask's answer is `<answer task="…">…</answer>`. A waited spawn's
  # await renders as the child's reply, naming the child:
  #
  #   <task_result task="r3t1" status="completed" conversation="…">
  #   …the reply…
  #   </task_result>
  #
  # The `task` attribute is the id the model saw: the CALL's key for a
  # branch a flat tool made, the step's own key for composed work — either
  # way the ROOT the tip continues, found by walking `source_round` back
  # through the kernel's promptless continuations. An empty tip says so.
  # The prompt, the call and the body ride through the one narrow escaper:
  # a tip that spells `</task_result>` or `<message ` cannot close
  # this envelope or forge another; everything else in it is untouched.
  class TaskResultEnvelope
    EMPTY = "(task completed with no output)".freeze
    CANCELED = "(task canceled by the person)".freeze
    # An expired or canceled spawn wait leaves the child untouched. Its
    # turn-owned completion wakes this execution; conversation-lifetime work
    # can report through later mail.
    SPAWN_DETACHED = "(still running; its reply reaches you later as a message that is not from the person)".freeze
    # What a reading model can do about work a provider declined, after the
    # kernel's sentence says what happened: the same request usually earns
    # the same refusal, so it goes on without the result or reports it. One
    # line for every declined tip, outside the detail's 256 characters.
    DECLINED = "(the same request is likely refused again: continue without this result, " \
               "or report that the provider refused it)".freeze
    PROMPT_CHARS = 80
    # The roots the flat tools mint under the call's kernel-authored key:
    # `r3t1-model-1`, `r3t1-ask-1` and `r3t1-spawn-1` / `-delegation-1` / `-wait-1`.
    FLAT_ROOT = /\A(?<call>r\d+t\d+)-(?:model|ask|spawn|delegation|wait)-1\z/

    class << self
      def for(tip, boundary: false) = new(tip, boundary: boundary).render

      # The key the envelope names — what the paired-result substitution
      # matches a `task` or `spawn` call by.
      def call_key(tip, boundary: false) = new(tip, boundary: boundary).call_key

      # Where the envelope says the tip came from, as a row: the tip itself
      # when it is a tool's, the flat call it continues, else the root step
      # whose brief it carries — never a key or a conversation id, so the
      # repeat brake knows the same work saying the same thing again.
      def origin(tip) = new(tip).origin

      # A child reply names the spawn or send call that opened its turn.
      # The initial spawn's await and the mail path share these bytes.
      # A scheduled occurrence also names its accepted brief and nominal time;
      # its creation need not appear in the receiving conversation's history.
      def child_reply(call_key:, status:, conversation_public_id:, body:, prompt: nil, scheduled_for: nil)
        occurrence = " scheduled_for=\"#{scheduled_for.utc.iso8601(6)}\"" if scheduled_for
        ["<task_result task=\"#{call_key}\" status=\"#{status}\" conversation=\"#{conversation_public_id}\"#{occurrence}>",
         prompt_line(prompt), escape(body), "</task_result>"].compact.join("\n")
      end

      def prompt_line(prompt)
        "<prompt>#{escape(prompt.first(PROMPT_CHARS))}</prompt>" if prompt.present?
      end

      def escape(text) = Conversations::ContextAssembly::SpeakerEnvelope.escape(text)
    end

    # `boundary`: the read crosses a stage's result boundary the reader is
    # not inside (`InputComposition#delivered_sources`).
    def initialize(tip, boundary: false)
      @tip = tip
      @boundary = boundary
    end

    def render
      if spawn_call
        return self.class.child_reply(call_key: call_key, status: @tip.status,
          conversation_public_id: spawn_call.spawned_conversation&.public_id, body: body)
      end
      return "<answer task=\"#{call_key}\">#{self.class.escape(body)}</answer>" if @tip.await? && !@tip.observing_task?

      ["<task_result task=\"#{call_key}\" status=\"#{@tip.status}\">", origin_line,
       self.class.escape(body), "</task_result>"].compact.join("\n")
    end

    def call_key = @boundary ? @tip.node_key : flat_call&.node_key || root.node_key

    def origin = @tip.tool_call? ? @tip : flat_call || root

    private

      # The line naming where the tip came from: a tool's call on every
      # read, else the brief, which a read across a stage's boundary leaves
      # out; nil when there is neither.
      def origin_line
        if @tip.tool_call?
          "<call>#{self.class.escape(@tip.call_head)}</call>"
        else
          prompt = prompt_text unless @boundary
          self.class.prompt_line(prompt)
        end
      end

      # A model can answer before its requested expansion fails, so keep
      # both its output and the later failure. Other tasks' output is the
      # settlement report itself and already takes precedence over its code.
      # A person's cancel — the one cancel that RESOLVES, read off the
      # adjudication axis — and a provider's decline say so in words the
      # model can act on.
      def body
        text = @tip.output_body&.effective_text
        return text if text.present? && !@tip.round?

        reason =
          if spawn_call && @tip.await? && %w[timed_out canceled].include?(@tip.status)
            SPAWN_DETACHED
          elsif @tip.failure_resolution == CancelBranch::RESOLUTION
            CANCELED
          else
            [[@tip.error_key, @tip.error_detail].compact_blank.join(": "),
             (DECLINED if @tip.error_key == ModelInvocation::DECLINED_KEY)].compact.join("\n")
          end
        [text, reason].compact_blank.join("\n\n").presence || EMPTY
      end

      # A branch made by `task` carries the CALL's prompt; composed work
      # carries the ROOT step's brief — the tip's own rounds are promptless.
      def prompt_text
        call = flat_call
        return Hash.try_convert(call.tool_input)&.fetch("prompt", nil).to_s if call&.tool_name == "task"

        root.content_bodies.find_by(role: "input")&.effective_text
      end

      # The `spawn` call whose await or completion this tip is, or nil.
      def spawn_call
        return nil if @boundary
        return @spawn_call if defined?(@spawn_call)

        call = (flat_call if @tip.await? || @tip.delegation?)
        @spawn_call = (call if call&.tool_name == "spawn")
      end

      # The `task`/`ask`/`spawn` call whose namespace names the root, or
      # nil for anything else the round reads.
      def flat_call
        return @flat_call if defined?(@flat_call)

        match = root.node_key.match(FLAT_ROOT)
        call = match && @tip.agent_loop.agent_loop_nodes.find_by(node_key: match[:call])
        @flat_call = (call if call&.tool_call? && BranchTools::FLAT_VERBS.include?(call.tool_name))
      end

      # Back along the branch's own spine to the step that was AUTHORED: a
      # kernel continuation is promptless and continues its source, a
      # composed or delegated step has its brief.
      def root
        return @root if defined?(@root)

        node = @tip
        while continuation?(node) && (source = InputComposition.source_round(node))
          node = source
        end
        @root = node
      end

      def continuation?(node) = node.round? && node.content_bodies.where(role: "input").none?
  end
end
