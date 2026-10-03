module Admin
  module UsersHelper
    # The membership panel's rows for one member.
    def member_facts(member)
      facts = {
        "Email" => member.email || "—",
        "Kind" => member.kind,
        "Role" => member.role,
        "Status" => member.status,
        "Joined" => member.created_at.to_date.to_fs(:long),
      }
      facts["Steward"] = steward_fact(member.steward) if member.agent?
      facts
    end

    private

      def steward_fact(steward)
        return "—" if steward.nil?

        steward.active? ? steward.display_name : "#{steward.display_name} (#{steward.status})"
      end
  end
end
