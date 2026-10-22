module OAuth
  module DeviceGrantsHelper
    def device_grant_facts(grant)
      {
        t("oauth.device.facts.type") => grant.runner_only_connection? ? device_grant_machine_label(grant) : t("oauth.device.agent_program"),
        t("oauth.device.facts.expires") => t("oauth.device.expires_from_now", time: time_ago_in_words(grant.expires_at)),
      }
    end
  end
end
