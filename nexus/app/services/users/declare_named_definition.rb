module Users
  # THE NAMED DEFINITION'S ONE WRITER: a paired agent profile declares a
  # DEFINITION of its own — a `users` row of kind agent under the composed
  # identifier `<caller identifier>/<name>`, the caller's steward, no
  # credential and no address — as a whole replacement: find-or-new by
  # `(account_id, agent_identifier)`, the configuration columns
  # through the one writer `DeclareConfiguration`, the `system_prompt` slot
  # through the prompt door's own writer, in ONE transaction. The declarer
  # is locked before a found definition; database uniqueness remains the
  # final guard against other registration writers. The scope may flip on the same
  # row (`instance` → `steward` is publish); the row, its handle, its
  # public id and its identifier never change. A found row with NO scope is
  # a PAIRED program's — never adopted (`identifier_taken`).
  class DeclareNamedDefinition
    SYSTEM_PROMPT_SLOT = "system_prompt".freeze

    def self.call(...) = new(...).call

    def initialize(caller:, name:, scope:, description:, configuration:, display_name: nil, system_prompt: nil)
      @caller = caller
      @name = name.to_s
      @scope = scope
      @description = description
      @configuration = configuration
      @display_name = display_name
      @system_prompt = system_prompt
    end

    def call
      return Outcome.new(outcome: :not_agent, user: @caller) unless @caller.agent_member?
      return Outcome.new(outcome: :invalid_name, user: @caller) unless @name.match?(User::Handle::FORMAT)

      outcome = nil
      # Removal uses this same parent before its instance definitions. Holding
      # it through declaration prevents a late create or restore escaping that cut.
      @caller.with_lock do
        outcome = if @caller.execution_principal_eligible?
          declare
        else
          Outcome.new(outcome: :not_authorized, user: @caller)
        end
        raise ActiveRecord::Rollback unless outcome.accepted?
      end
      outcome
    rescue ActiveRecord::RecordNotUnique
      Outcome.new(outcome: :concurrent_write, user: @caller)
    end

    private

      def identifier = "#{@caller.agent_identifier}#{User::NamedDefinition::DEFINITION_SEPARATOR}#{@name}"

      def declare
        found = User.find_by(account_id: @caller.account_id, agent_identifier: identifier)
        if found && (found.definition_scope.nil? || found.steward_id != @caller.steward_id)
          return Outcome.new(outcome: :identifier_taken, user: found)
        end

        row = found || new_row
        if found
          # Lock the definition after its declarer, as removal does; its prompt
          # documents are replaced under this same definition lock.
          row.lock!
          restored = row.removed? ? row.restore : :active
          return Outcome.new(outcome: :shutdown_pending, user: row) if restored == :shutdown_pending
        end
        row.assign_attributes(
          derived_from: @caller, definition_scope: @scope, description: @description,
          display_name: @display_name.presence || @name
        )
        # The old slot goes BEFORE the declaration: the declaration judges
        # the standing document's macros against the new template, and the
        # new body is judged the same way once the template stands.
        PromptDocuments::Delete.call(anchor: { user: row }, slot: SYSTEM_PROMPT_SLOT) if found
        declared = DeclareConfiguration.call(user: row, **@configuration)
        return declared unless declared.accepted?

        refusal = write_slot(row)
        return refusal if refusal

        Outcome.new(outcome: found ? :replaced : :declared, user: row)
      end

      def new_row
        User.new(
          account: @caller.account, kind: :agent, role: :member, steward: @caller.steward,
          agent_identifier: identifier, handle_base: @name
        )
      end

      # The body is the row's `system_prompt` document; none deletes it.
      def write_slot(row)
        return if @system_prompt.nil?

        result = PromptDocuments::Write.call(anchor: { user: row }, slot: SYSTEM_PROMPT_SLOT, content: @system_prompt)
        Outcome.new(outcome: result.outcome, user: row, detail: result.detail) unless result.written?
      end
  end
end
