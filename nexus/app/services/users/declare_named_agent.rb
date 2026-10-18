module Users
  # THE NAMED DEFINITION'S ONE WRITER: a paired agent profile declares a
  # DEFINITION of its own — a `users` row of kind agent under the composed
  # identifier `<caller identifier>/<name>`, the caller's steward, no
  # credential and no address — as a whole replacement: find-or-new by
  # `(account_id, agent_identifier)`, the configuration columns
  # and both prompt slots through `ConfigureAgent`, in ONE transaction. The declarer
  # is locked before a found definition; database uniqueness remains the
  # final guard against other registration writers. The scope may flip on the same
  # row (`instance` → `steward` is publish); the row, its handle, its
  # public id and its identifier never change. A found row with NO scope is
  # a PAIRED program's — never adopted (`identifier_taken`).
  class DeclareNamedAgent
    def self.call(...) = new(...).call

    def initialize(caller:, name:, scope:, description:, configuration:, display_name: nil,
                   system_prompt: nil, summarizer: nil, create_only: false)
      @caller = caller
      @name = name.to_s
      @scope = scope
      @description = description
      @configuration = configuration
      @display_name = display_name
      @system_prompt = system_prompt
      @summarizer = summarizer
      @create_only = create_only
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

      def identifier = "#{@caller.agent_identifier}#{User::NamedAgent::NAMED_AGENT_SEPARATOR}#{@name}"

      def declare
        found = User.find_by(account_id: @caller.account_id, agent_identifier: identifier)
        return Outcome.new(outcome: :name_taken, user: found) if found && @create_only

        if found && (found.named_agent_scope.nil? || found.steward_id != @caller.steward_id)
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
          derived_from: @caller, named_agent_scope: @scope, description: @description,
          display_name: @display_name.presence || @name
        )
        declared = ConfigureAgent.declare_locked(user: row, configuration: @configuration,
          system_prompt: (@system_prompt.nil? ? nil : { content: @system_prompt }),
          summarizer: (@summarizer.nil? ? nil : { content: @summarizer }))
        return declared unless declared.accepted?

        Outcome.new(outcome: found ? :replaced : :declared, user: row)
      end

      def new_row
        User.new(
          account: @caller.account, kind: :agent, role: :member, steward: @caller.steward,
          agent_identifier: identifier, handle_base: @name
        )
      end
  end
end
