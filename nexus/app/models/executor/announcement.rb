# One whole-address writer and role-qualified readers. Withdrawing a role
# changes new admission, never the authority of an already accepted claim.
module Executor::Announcement
  extend ActiveSupport::Concern

  included do
    attribute :services, Executor::Services.to_type
    before_validation :initialize_services, on: :create
    validate :services_must_be_bounded
    scope :providing, ->(role) { where("jsonb_typeof(services -> :role) = 'object'", role: role.to_s) }
  end

  def announce(services:)
    refusal = services_refusal(services)
    if refusal
      Executors::Outcome.refused(refusal.code.to_sym, self, detail: refusal.detail)
    else
      self.services = services.to_h do |role, service|
        [role, {
          "tools" => Nexus::ToolAnnouncements.canonical(service.fetch("tools")),
          "documents" => Nexus::ToolAnnouncements.canonical_documents(service["documents"]),
          "environment" => service["environment"] || {},
        }]
      end
      save ? Executors::Outcome.accepted(self) : Executors::Outcome.refused(:invalid, self)
    end
  end

  def service_roles = services.roles
  def provides?(role) = service_roles.include?(role.to_s)
  def tools_for(role) = services.for(role)&.tools || []
  def documents_for(role) = services.for(role)&.documents || []
  def environment_for(role) = services.for(role)&.environment || {}
  def served?(name, role:) = serving(name, role: role).present?

  def serving(name, role:)
    tools_for(role).find { |entry| entry.fetch("name") == name.to_s }
  end

  def effect_profile_for(name, role:)
    entry = serving(name, role: role)
    entry&.fetch("effect_profile")&.merge(entry.slice("timeout_ms"))
  end

  private

    def initialize_services
      self.services ||= { executor_kind => {} }
    end

    def services_refusal(document)
      document = Hash.try_convert(document)
      allowed = agent? ? %w[agent runner] : [executor_kind]
      unless document && document.key?(executor_kind) && (document.keys - allowed).empty?
        return Nexus::ToolAnnouncements::Refusal.new(code: "invalid_announcement", detail: "services must include the registration role and only its permitted roles")
      end

      document.each_value do |service|
        service = Hash.try_convert(service)
        unless service
          return Nexus::ToolAnnouncements::Refusal.new(code: "invalid_announcement", detail: "service must be an object")
        end
        refusal = Nexus::ToolAnnouncements.refusal(service["tools"]) ||
          Nexus::ToolAnnouncements.document_refusal(service["documents"]) ||
          Nexus::ToolAnnouncements.environment_refusal(service["environment"])
        return refusal if refusal
      end
      nil
    end

    def services_must_be_bounded
      if services && (!Nexus::SizeBounds.json_within?(:envelope_bound, services.document) ||
          services.roles.any? { |role| !Nexus::SizeBounds.json_within?(:executor_environment_bound, services.for(role).environment) })
        errors.add(:services, Nexus::SizeBounds::REJECTION)
      end
    end
end
