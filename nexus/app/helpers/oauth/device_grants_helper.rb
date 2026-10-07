module OAuth
  module DeviceGrantsHelper
    # The grant panel's rows: what is asking, and how long the ask stands. A
    # combined grant is the agent's page plus ONE row, in the page's own
    # words. A new runner is private; a reconnect keeps its existing scope.
    def device_grant_facts(grant, existing_runner:)
      {
        "Type" => grant.runner_only_connection? ? device_grant_machine_label(grant) : "Agent program",
        "Expires" => "#{time_ago_in_words(grant.expires_at)} from now",
        **({ "Also" => combined_runner_sentence(grant, existing_runner: existing_runner) } if grant.combined_connection?).to_h,
      }
    end

    def combined_runner_sentence(grant, existing_runner:)
      scope =
        if existing_runner&.account_wide?
          "available account-wide for authorized discovery and new work."
        elsif grant.connected?
          "private to Agents managed by the member who connected it."
        else
          "private to the Agents you manage."
        end

      "Also runs as a runner on that machine — it can read, write and run commands there — #{scope}"
    end
  end
end
