module Rho
  module Dev
    # THE VERB-BEARING RENDERERS: the shared renderers in
    # `Rho::Cli::Reporting` print a line's FACT and leave its hint to a
    # hook — the shipped terminal names the capability (a product home has
    # no second verb to name), and a terminal this gem extends names the
    # verb a developer types. Mixed into the one terminal a verb receives
    # (`Rho::Dev.terminal`), so the pushed stream, the poll and the inbox
    # rows all print the same hints the e2e lanes read.
    module Hints
      # `uncertain` is the one word a person must act on by hand: the tool's executor expired without a result and its effect
      # may have happened, so nothing re-runs it blind — the line says
      # which two verbs decide it.
      UNCERTAIN_HINT = "effect uncertain: check, then `rho retry` or `rho abandon`".freeze

      private

        def uncertain_hint = UNCERTAIN_HINT

        def ask_hint(ask)
          "answer:    rho answer #{ask["run_public_id"]} #{ask["task_key"]} \"…\""
        end

        # A STEP A PROVIDER DECLINED and nothing re-ran: the verb that
        # re-runs it on another model, keyed to the step; for blocked content
        # the verb that moves past it — it is re-sent to no model.
        def refusal_hint(run_public_id, task_key, blocked:)
          return "`rho abandon #{run_public_id} #{task_key}`, then rephrase: blocked content is never re-sent" if blocked

          "`rho retry #{run_public_id} #{task_key} --model provider/model` re-runs it on another model"
        end

        # THE PARK LINE'S TAIL: both verbs as hints — a
        # person decides ONE call whose arguments they have read, so the
        # key is on the line.
        def approval_tail(row)
          run_id = row["run_public_id"]
          key = row["task_key"]
          "  → rho approve #{run_id} #{key} | rho deny #{run_id} #{key} [reason]"
        end
    end
  end
end
