module Admin
  module UsersHelper
    # The membership panel's rows for one member.
    def member_facts(member)
      facts = {
        t("members.facts.email") => member.email || "—",
        t("members.facts.kind") => t("members.kinds.#{member.kind}"),
        t("members.facts.role") => t("members.roles.#{member.role}"),
        t("members.facts.status") => t("members.statuses.#{member.status}"),
        t("members.facts.joined") => l(member.created_at.to_date, format: :long),
      }
      facts[t("members.facts.steward")] = steward_fact(member.steward) if member.agent?
      facts
    end

    private

      def steward_fact(steward)
        return "—" if steward.nil?

        steward.active? ? steward.display_name : t("members.inactive_name", name: steward.display_name, status: t("members.statuses.#{steward.status}"))
      end
  end
end
