# A configuration capture belongs to the execution, while access, attribution
# and executor addressing continue to use its actual User principal.
module DeclaredExecution
  extend ActiveSupport::Concern

  included do
    attribute :execution_declaration, ExecutionDeclaration.to_type
    validates :execution_declaration, store_model: true, allow_nil: true
    validates :execution_declaration_document, bounded_json: { bound: :snapshot_bound }, allow_nil: true
  end

  def execution_configuration = execution_declaration || declaring_profile

  private

    def execution_declaration_document = execution_declaration&.as_json
end
