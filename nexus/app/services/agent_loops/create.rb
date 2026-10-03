module AgentLoops
  # The loop's front door: one workspace-gated build plus the seed batch
  # through the ONE append door, in one transaction — a loop is born with
  # its graph or not at all.
  class Create
    Command = Data.define(
      :workspace, :creating_user, :steps, :billing_subject, :idempotency_key,
      :prompt_mechanism, :approval_mode, :approval_rules, :runner_executor_public_id
    ) do
      def initialize(prompt_mechanism: nil, approval_mode: nil, approval_rules: nil,
                     runner_executor_public_id: nil, **) = super
    end

    # The configuration shell: one of the three mechanism words — `raw`: the
    # seed task's own prompt, instructions and tools ARE the request; `default`
    # / `assembly`: the seed is COMPILED ONCE here by the one assembler over a
    # standalone `Source` (the creator's slots, the room's and the creator's
    # memory, no history; no model resolved, so no window sizes it) and sealed
    # in place of the seed step's authored body, the words the step's `prompt`
    # — and one of `bypass|ask|rules` with an optional rule list; NOTHING IS
    # DEFAULTED — a nil approval mode is refused by name, as is a word outside
    # either vocabulary. The shell IS the loop's declaration: its word wins
    # over the creator profile's standing one. A loop-backed turn's word is
    # materialization's, never this door's.
    PROMPT_MECHANISMS = User::AgentConfiguration::PROMPT_MECHANISMS

    Result = Data.define(:outcome, :agent_loop, :receipt, :errors) do
      class << self
        def created(agent_loop, receipt)
          new(outcome: :created, agent_loop: agent_loop, receipt: receipt, errors: [])
        end

        def replayed(agent_loop, receipt)
          new(outcome: :replayed, agent_loop: agent_loop, receipt: receipt, errors: [])
        end

        def refused(code) = new(outcome: code, agent_loop: nil, receipt: nil, errors: [])

        def invalid(errors)
          new(outcome: :invalid_steps, agent_loop: nil, receipt: nil, errors: errors)
        end
      end

      def created? = outcome == :created
      def replayed? = outcome == :replayed
    end

    class << self
      def call(command)
        new(command).call
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      unless @command.workspace.data_writable_by?(@command.creating_user)
        return Result.refused(:not_authorized)
      end
      return Result.refused(:steps_required) if Array(@command.steps).empty?
      shell = shell_refusal
      return Result.refused(shell) if shell

      replay = replayed_create
      return replay if replay

      attribution = verified_billing_attribution
      return Result.refused(:billing_subject_not_owned) if attribution.nil?

      # The initial runner binding, the host's from birth: the runner
      # the creator names; the kernel infers none.
      binding = Executors::InitialRunner.for(
        requested: @command.runner_executor_public_id, principal: @command.creating_user
      )
      return Result.refused(:runner_not_eligible) if binding.refused?

      agent_loop = nil
      appended = nil
      seed_refusal = nil
      AgentLoop.transaction do
        creating_user = @command.creating_user
        agent_loop = AgentLoop.create!(
          workspace: @command.workspace,
          creating_user: creating_user,
          prompt_mechanism: @command.prompt_mechanism,
          # The shell, frozen onto the row: the scheduler reads THIS,
          # never the profile of the day.
          approval_mode: @command.approval_mode,
          approval_rules: @command.approval_rules.presence,
          lifecycle_hooks: creating_user.lifecycle_hooks,
          runner_executor: binding.executor,
          **attribution
        )
        # Born with its event cursor, so no two first appenders ever
        # race to create it.
        agent_loop.create_conversation_event_cursor!(account: agent_loop.account)
        # The seed is an authored envelope on an empty loop: its end tip is
        # the answer by construction, so nothing names one.
        appended = Tasks::Append.call(Tasks::Append::Command.authored(
          agent_loop: agent_loop, steps: @command.steps, creator: creating_user
        ))
        raise ActiveRecord::Rollback unless appended.applied?

        seed_refusal = compile_seed(agent_loop, appended.receipt) if seed_template
        raise ActiveRecord::Rollback if seed_refusal

        persist_create_receipt(agent_loop)
      end
      return seed_refusal if seed_refusal
      return Result.created(agent_loop, appended.receipt) if appended&.applied?
      return Result.invalid(appended.errors) if appended && appended.outcome == :invalid_steps

      Result.refused(appended&.outcome || :not_available)
    rescue ActiveRecord::RecordNotUnique
      # The retry raced the original past the pre-check; the receipt the
      # winner wrote is the answer.
      replayed_create || Result.refused(:idempotency_envelope_mismatch)
    end

    private

      # The raw string becomes the frozen verified pair or the create is
      # refused: a receipt is immutable, so an unverified string would lose
      # the spend's attribution forever. Nil only for a key owned by somebody else.
      def verified_billing_attribution
        key = @command.billing_subject
        return {} if key.blank?

        result = BillingSubjects::CreateOrVerify.call(
          account: @command.workspace.account,
          acting_user: @command.creating_user,
          key: key
        )
        return nil unless result.verified?

        {
          billing_subject_key: result.billing_subject.key,
          billing_subject_public_id: result.billing_subject.public_id,
        }
      end

      # A mechanism outside the vocabulary is refused as invalid; `assembly`
      # on a creator with no template of its own (a Human, or an agent that
      # stored none) is `prompt_template_missing`. The approval mode is one
      # of the three words or nothing at all is created: nil is
      # `invalid_approval_mode`, never bypass ("no silent default"); the
      # rule list is refused by the one evaluator's grammar.
      def shell_refusal
        mechanism = @command.prompt_mechanism
        return :invalid_prompt_mechanism unless mechanism.nil? || PROMPT_MECHANISMS.include?(mechanism)
        return :prompt_template_missing if mechanism == "assembly" && seed_template.nil?

        return :invalid_approval_mode unless
          User::AgentConfiguration::APPROVAL_MODES.include?(@command.approval_mode)
        return :invalid_approval_rules if Executors::Rules.refusal(@command.approval_rules)

        nil
      end

      # The block order the seed compiles under: the CREATOR profile's, by
      # the shell's word — nil under `raw` (nothing compiles).
      def seed_template
        return @seed_template if defined?(@seed_template)

        creator = @command.creating_user
        @seed_template = PromptTemplate.for_shell(
          @command.prompt_mechanism, (creator if creator.agent?)
        )
      end

      # THE SEED COMPILE: the first step is a model step whose authored words are the input block and whose
      # `instructions` is refused by name — the system channel rides the sealed list under an assembled word.
      # The one assembler runs over a standalone Source with no profile and no limits (FillCost at bytes/4, no
      # allocator — the exact window gate is the scheduler's), and the compiled list REPLACES the authored
      # body, sealed (`ModelTask#input_value` reads that one body; every continuation replays it as the
      # prefix). Memory — and the skills catalog beside it — is thereby FROZEN at create for the loop's life.
      # The creator's words stay the body's readable text — what the summarizer's `authored_prompt` and the
      # task read render — so no slot text and no memory value ever reach a summary. Answers the refusal, nil
      # when sealed.
      def compile_seed(agent_loop, receipt)
        first = Hash.try_convert(@command.steps.first)&.to_h&.transform_keys(&:to_s) || {}
        return Result.invalid([{ "code" => "seed_not_a_model_step", "path" => "steps[0]" }]) unless first.key?("model")

        node = agent_loop.agent_loop_nodes.find_by!(node_key: receipt.fetch("accepted_task_keys").first)
        if node.system_instructions.present?
          return Result.invalid([{ "code" => "instructions_raw_only", "path" => "steps[0].instructions" }])
        end

        authored = node.content_bodies.find_by!(role: "input")
        creator = agent_loop.creating_user
        assembled = Conversations::ContextAssembly.assemble(
          source: Conversations::ContextAssembly::Source.standalone(agent_loop.workspace),
          principal: creator, prompt: authored.readable_text, attachments: authored.upload_parts,
          declaring_profile: agent_loop.declaring_profile, answerer: creator, template: seed_template,
          # The seed step's compiled tools and the loop's bound runner: the
          # skills block renders the catalog this loop can load (II 3.3).
          tools: node.tool_definitions, runner: agent_loop.bound_runner
        )
        words = authored.readable_text
        authored.destroy!
        sealed = ContentBodies::Replace.call(
          owner: node, role: "input", entries: Nexus::InputEntries.for(assembled.messages),
          uploads: assembled.uploads, composed: true, seal: true, readable_text: words
        )
        Result.refused(sealed.refusal) unless sealed.accepted?
      end

      def create_digest
        AgentLoopAppendReceipt.digest_for(
          "steps" => @command.steps,
          "billing_subject" => @command.billing_subject,
          "prompt_mechanism" => @command.prompt_mechanism,
          "approval_mode" => @command.approval_mode,
          "approval_rules" => @command.approval_rules,
          "runner_executor_public_id" => @command.runner_executor_public_id
        )
      end

      # A retried create cannot name the loop the lost response minted —
      # the workspace-scoped receipt is how it finds it. Expired receipts
      # are deleted at lookup (the family idiom).
      def replayed_create
        key = @command.idempotency_key
        return nil if key.blank?

        # Release only the key being consulted. The hourly reaper owns bulk
        # cleanup, so an ordinary create never drains other callers' receipts.
        scope = AgentLoopCreateReceipt.where(
          workspace_id: @command.workspace.id,
          creating_user_id: @command.creating_user.id,
          idempotency_key: key
        )
        scope.where(created_at: ...AgentLoopCreateReceipt::RETENTION.ago).delete_all
        receipt = scope.first
        return nil if receipt.nil?
        return Result.refused(:idempotency_envelope_mismatch) unless
          receipt.request_digest == create_digest
        # A tombstone removes the loop from EVERY product surface, and the
        # replay is a surface: resurfacing a deleted loop's full trace here
        # is the one hole the `listable` scope did not cover.
        return Result.refused(:agent_loop_deleted) if receipt.agent_loop.tombstoned?

        # Authored appends advance revision from zero under the loop lock;
        # revision one is always the seed, even after later appends. Its
        # receipt restores any answer tokens lost with the create response.
        seed = receipt.agent_loop.agent_loop_append_receipts
          .find_by!("response_body ->> 'revision' = ?", "1")
        Result.replayed(receipt.agent_loop, seed.response_body)
      end

      def persist_create_receipt(agent_loop)
        key = @command.idempotency_key
        return if key.blank?

        AgentLoopCreateReceipt.create!(
          account: agent_loop.account,
          workspace: @command.workspace,
          creating_user: @command.creating_user,
          agent_loop: agent_loop,
          idempotency_key: key,
          request_digest: create_digest,
          # The create replay window must end before its seed receipt can
          # expire, including time spent compiling after the seed append.
          created_at: agent_loop.created_at
        )
      end
  end
end
