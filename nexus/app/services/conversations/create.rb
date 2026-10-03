module Conversations
  # Deliberately small: speakers resolve lazily per input, the stream
  # starts with the first input. A SPAWNED child is this same create with
  # the PARENT ARM: `parent` and `spawn_node` given, the child hangs off
  # the parent conversation, copies its carrier, billing pair and runner,
  # and is answered by the chosen profile through the one door.
  class Create
    # `access` is the carrier's birth shape: `{"default" => …, "entries" =>
    # [{"user_public_id", "level"}]}` as the wire spells it, nil for the
    # ordinary `full` with no entries. `parent`, `spawn_node` and
    # `spawn_label` are the kernel's own arm — never a controller's.
    Command = Data.define(
      :workspace, :creating_user, :title, :metadata, :billing_subject,
      :runner_executor_public_id, :answering_user_public_id, :access,
      :parent, :spawn_node, :spawn_label, :memory_context, :scheduled_job, :scheduled_for
    ) do
      def initialize(runner_executor_public_id: nil, answering_user_public_id: nil, access: nil,
                     parent: nil, spawn_node: nil, spawn_label: nil, memory_context: nil,
                     scheduled_job: nil, scheduled_for: nil, **) = super

      def spawned? = !parent.nil?
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
        return Outcome.refused(:not_authorized)
      end
      # A side never spawns: its children would orphan at its reap.
      return Outcome.refused(:side_conversation) if @command.spawned? && @command.parent.side?

      # THE ANSWERER, resolved before the runner: the profile the creator
      # names, else the creator itself — the door says what the model's
      # default means.
      answering_user = named_answerer
      return Outcome.refused(:answerer_not_eligible) if answering_user.nil?

      refusal = billing_refusal
      return refusal if refusal

      binding = runner_binding(answering_user)
      return Outcome.refused(:runner_not_eligible) if binding.refused?

      entries = birth_entries(answering_user)
      return Outcome.refused(:principal_not_eligible) if entries.nil?

      conversation = Conversation.new(
        workspace: @command.workspace,
        creating_user: @command.creating_user,
        answering_user: answering_user,
        title: normalized_title,
        metadata: @command.metadata || {},
        memory_context: @command.spawn_node ? @command.spawn_node.agent_loop.memory_context : @command.memory_context,
        runner_executor: binding.executor,
        conversation_access_entries: entries,
        **access_default,
        **billing_pair,
        **parent_link
      )
      return Outcome.invalid(conversation) unless conversation.valid?
      context = MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation,
        principal: @command.creating_user, configuration: conversation.memory_context)
      return Outcome.refused(:memory_scope_unavailable) unless context.sources_available?

      Conversation.transaction do
        if conversation.save
          # The host is born with its event cursor, so no two first
          # appenders ever race to create it.
          conversation.create_conversation_event_cursor!(account: conversation.account)
          Outcome.accepted(conversation)
        else
          Outcome.invalid(conversation)
        end
      end
    end

    private

      # The named answerer: `Workspace#answerer_eligible?` — an agent
      # profile of the account that may write in this workspace. Anything
      # else — an unknown id, a Human, the system user, a suspended or
      # fenced profile — conceals as ineligibility, as `InitialRunner`
      # does. Unnamed is the creator.
      def named_answerer
        requested = @command.answering_user_public_id
        return @command.creating_user if requested.blank?

        user = User.where(account_id: @command.workspace.account_id).find_by(public_id: requested)
        user if @command.workspace.answerer_eligible?(user)
      end

      # The initial runner binding, the host's from birth: the runner the
      # creator names, judged for the ANSWERER — the principal every call
      # will be judged for; the kernel infers none. A spawned child
      # inherits the parent's bound runner when it is eligible for the
      # child's answerer, else NONE: eligibility is judged, absence is
      # lawful, never a refusal of the spawn.
      def runner_binding(answering_user)
        requested = @command.spawned? ? @command.parent.bound_runner&.public_id : @command.runner_executor_public_id
        binding = Executors::InitialRunner.for(requested: requested, principal: answering_user)
        binding.refused? && @command.spawned? ? Executors::InitialRunner::Decision.new(executor: nil) : binding
      end

      # THE ACCESS CARRIER AT BIRTH: the named principals resolved as the
      # later change resolves them — the creator and the answerer are full
      # by derivation and never rows; the default and the levels are the
      # records' own enums (`invalid`, never a raise). A spawned child
      # COPIES its parent's carrier by the fork rule: the parent's entries
      # plus its derived-full pair materialized as `full`, minus the
      # child's own derived pair (the spawner is its creator, the chosen
      # profile its answerer). Read lock-free: a narrowing landing
      # concurrently can be missed on the child — parity with the workspace
      # rule, no corruption.
      def birth_entries(answering_user)
        derived = [@command.creating_user.id, answering_user.id]
        return spawned_entries(derived) if @command.spawned?

        principals = AccessPrincipals.resolve(
          account_id: @command.workspace.account_id,
          derived_user_ids: derived,
          entries: Array(access["entries"])
        )
        principals&.map do |principal|
          ConversationAccessEntry.new(user: principal.user, level: principal.level)
        end
      end

      def spawned_entries(derived)
        parent = @command.parent
        ConversationAccessEntry.where(conversation_id: parent.id).pluck(:user_id, :level).to_h
          .merge(parent.creating_user_id => "full", parent.answering_user_id => "full")
          .except(*derived)
          .map { |user_id, level| ConversationAccessEntry.new(user_id: user_id, level: level) }
      end

      # The child hangs off the parent CONVERSATION (never a branch or a
      # node) and names the call that minted it; the public-id snapshot
      # survives the parent's reap.
      def parent_link
        return {} unless @command.spawned?

        {
          parent_conversation: @command.parent,
          parent_conversation_public_id: @command.parent.public_id,
          spawn_node: @command.spawn_node,
          spawn_label: @command.spawn_label,
          scheduled_job: @command.scheduled_job,
          scheduled_job_public_id: @command.scheduled_job&.public_id,
          scheduled_for: @command.scheduled_for,
        }
      end

      def normalized_title
        title = @command.title.to_s.strip
        title.empty? ? nil : title
      end

      def access = @command.access || {}

      # Absent is the attribute's own default (`full`); a word the caller
      # sent — known or not — reaches the enum's validation. The envelope
      # carries the key as nil when the caller omitted it, so absence is
      # read by value. A spawned child's default is its parent's.
      def access_default
        return { access_default: @command.parent.access_default } if @command.spawned?

        access["default"].nil? ? {} : { access_default: access["default"] }
      end

      # Submit-time billing attribution, the OneShot shape verbatim: verify
      # or create the subject, copy the create-frozen pair. Fork and spawn
      # copy the parent's pair instead of re-verifying (recorded).
      def billing_verification
        return @billing_verification if defined?(@billing_verification)

        key = @command.billing_subject.to_s.strip
        @billing_verification =
          if key.empty? || @command.spawned?
            nil
          else
            BillingSubjects::CreateOrVerify.call(
              account: @command.workspace.account,
              acting_user: @command.creating_user,
              key: key
            )
          end
      end

      def billing_refusal
        verification = billing_verification
        return nil if verification.nil? || verification.verified?

        if verification.not_owner?
          Outcome.refused(:billing_subject_not_owned)
        else
          Outcome.refused(:billing_subject_invalid)
        end
      end

      def billing_pair
        if @command.spawned?
          return {
            billing_subject_key: @command.parent.billing_subject_key,
            billing_subject_public_id: @command.parent.billing_subject_public_id,
          }
        end

        verification = billing_verification
        return {} if verification.nil?

        {
          billing_subject_key: verification.billing_subject.key,
          billing_subject_public_id: verification.billing_subject.public_id,
        }
      end
  end
end
