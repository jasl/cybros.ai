# A closed set of role announcements on one delivery address. Each role has
# its own tool namespace; the address, credentials and lifecycle remain shared.
class Executor::Services
  include StoreModel::Model

  class Service
    include StoreModel::Model

    attribute :tools, default: -> { [] }
    attribute :documents, default: -> { [] }
    attribute :environment, default: -> { {} }
  end

  ROLES = %w[agent runner tool_provider].freeze

  attribute :agent, Service.to_type
  attribute :runner, Service.to_type
  attribute :tool_provider, Service.to_type

  def roles = ROLES.select { |role| public_send(role) }

  def for(role) = public_send(role)

  def as_json(options = nil) = document.as_json(options)

  def document
    roles.to_h { |role| [role, self.for(role).attributes] }
  end
end
