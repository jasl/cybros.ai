module OAuth
  module DeviceGrantsHelper
    # The grant panel's rows: what is asking, and how long the ask stands. A
    # combined grant is the agent's page plus ONE row, in the page's own
    # words. Its Runner is private to the application and its named Agents.
    def device_grant_facts(grant)
      {
        t("oauth.device.facts.type") => grant.runner_only_connection? ? device_grant_machine_label(grant) : t("oauth.device.agent_program"),
        t("oauth.device.facts.expires") => t("oauth.device.expires_from_now", time: time_ago_in_words(grant.expires_at)),
        **({ t("oauth.device.facts.also") => t("oauth.device.combined_runner") } if grant.combined_connection?).to_h,
      }
    end
  end
end
