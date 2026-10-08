module OAuth
  module DeviceGrantsHelper
    # The grant panel's rows: what is asking, and how long the ask stands. A
    # combined grant is the agent's page plus ONE row, in the page's own
    # words. A new runner is private; a reconnect keeps its existing scope.
    def device_grant_facts(grant, existing_runner:)
      {
        t("oauth.device.facts.type") => grant.runner_only_connection? ? device_grant_machine_label(grant) : t("oauth.device.agent_program"),
        t("oauth.device.facts.expires") => t("oauth.device.expires_from_now", time: time_ago_in_words(grant.expires_at)),
        **({ t("oauth.device.facts.also") => combined_runner_sentence(grant, existing_runner: existing_runner) } if grant.combined_connection?).to_h,
      }
    end

    def combined_runner_sentence(grant, existing_runner:)
      scope =
        if existing_runner&.account_wide?
          :account_wide
        elsif grant.connected?
          :connected_private
        else
          :private
        end

      t("oauth.device.combined_runner.#{scope}")
    end
  end
end
