module Admin
  module UsersHelper
    def user_facts(member)
      {
        t("members.facts.email") => member.email,
        t("members.facts.role") => t("members.role_options.#{member.role}"),
        t("members.facts.status") => t("members.statuses.#{member.status}"),
        t("members.facts.joined") => l(member.created_at.to_date, format: :long),
      }
    end
  end
end
