module OAuth
  module DeviceGrantsHelper
    # The grant panel's rows: what is asking, and how long the ask stands. A
    # combined grant is the agent's page plus ONE row, in the page's own
    # words — no scope block, the in-process runner is always private to the
    # Agent Profiles the connecting human manages.
    COMBINED_RUNNER_SENTENCE =
      "Also runs as a runner on that machine — it can read, write and run commands " \
      "there — private to the Agent Profiles you manage.".freeze

    def device_grant_facts(grant)
      {
        "Type" => grant.runner_only_connection? ? device_grant_machine_label(grant) : "Agent program",
        "Expires" => "#{time_ago_in_words(grant.expires_at)} from now",
        **({ "Also" => COMBINED_RUNNER_SENTENCE } if grant.combined_connection?).to_h,
      }
    end
  end
end
