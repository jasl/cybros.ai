require_relative "rho_daemon"
require_relative "runner_grant"

module E2E
  # THE BROWSER HALF OF A DAEMON'S OWN CEREMONY (r-modes M2/M5): a person
  # walks the connection page a rho daemon opened and clicks Connect. ONE
  # helper for every rho journey, dispatching on the SHAPE THE DAEMON
  # PUBLISHED — `branch` in its `/device/start` answer (`Connection#to_h`):
  # `agent` and `combined` are the one agent page; `runner` is the machine
  # page with its scope block. Never the settings file, never `RHO_MODE`:
  # the harness passes the mode through the child's environment and does
  # not parse it back — the daemon's own document is the fact.
  #
  # THE ONE-SENTENCE PIN. A full-mode boot pairs the combined grant: the
  # agent page plus one facts row, in the page's own words, and the settled
  # page repeats it. An agent-mode boot (and the fence agent's grant) shows
  # no trace of a runner — the sentence's absence is asserted, not assumed.
  #
  # `status` is a callable answering the daemon's status document; when it
  # is given, the helper waits for the daemon to finish — `state` active
  # with the ceremony gone or itself active — on the daemon's poll cadence,
  # never a fixed sleep. `status: nil` is a grant no daemon owns (the fence
  # agent's).
  module Ceremony
    RUNNER_SENTENCE = "Also runs as a runner on that machine".freeze
    AGENT_SUBJECT = "agent program".freeze
    BRANCHES = %w[agent combined runner].freeze

    # What `RunnerGrant` reads off an authorization: the runner-mode daemon's
    # grant is branch B for a `runner`-kind registration.
    Authorization = Data.define(:verification_uri_complete, :user_code, :branch, :executor_kind)

    module_function

    def confirm(actor:, started:, status: nil)
      branch = started.fetch("branch") { raise ArgumentError, "the ceremony published no branch: #{started.inspect}" }
      raise ArgumentError, "unknown ceremony branch #{branch.inspect}" unless BRANCHES.include?(branch)

      if branch == "runner"
        confirm_runner_page(actor, started)
      else
        confirm_agent_page(actor, started, runner_sentence: branch == "combined")
      end
      await_active(status) if status
    end

    # The agent page as every rho journey walked it: the pre-filled code,
    # the subject, the code again, Connect, the settled sentence.
    def confirm_agent_page(actor, started, runner_sentence:)
      page = actor.page
      actor.visit(started.fetch("verification_uri_complete"))
      page.assert_selector(:field, "Device code", with: started.fetch("user_code"))

      page.click_button "Continue"
      page.assert_text("Connect #{AGENT_SUBJECT}")
      page.assert_text(started.fetch("user_code"))
      assert_runner_sentence(page, runner_sentence)

      page.click_button "Connect"
      # The waiting page — or, when the daemon collected its credential
      # before the page was read again (an idle box: the harbor cell's
      # sidecar on 2026-09-18), the completed one: the sentence's
      # presence was asserted on the confirm page above, where it is the
      # page's own word; here it is asserted while the page still waits.
      page.assert_text(/#{Regexp.escape(WAITING_SENTENCE)}|#{Regexp.escape(COMPLETE_SENTENCE)}/)
      assert_runner_sentence_after_connect(page, runner_sentence)
    end

    WAITING_SENTENCE = "Connection ready. Waiting for the #{AGENT_SUBJECT} to finish connecting.".freeze
    COMPLETE_SENTENCE = "This connection is complete".freeze

    def assert_runner_sentence(page, present)
      present ? page.assert_text(RUNNER_SENTENCE) : page.assert_no_text(RUNNER_SENTENCE)
    end

    # After Connect: the sentence, or the completion that replaced it.
    def assert_runner_sentence_after_connect(page, present)
      return page.assert_no_text(RUNNER_SENTENCE) unless present

      page.assert_text(/#{Regexp.escape(RUNNER_SENTENCE)}|#{Regexp.escape(COMPLETE_SENTENCE)}/)
    end

    # The machine page (`RunnerGrant`): the scope a plain member is offered
    # is private-only; a re-run inherits the registration's scope.
    def confirm_runner_page(actor, started)
      authorization = Authorization.new(
        verification_uri_complete: started.fetch("verification_uri_complete"),
        user_code: started.fetch("user_code"), branch: :runner, executor_kind: "runner"
      )
      RunnerGrant.visit_connection(actor: actor, authorization: authorization)
      offer = RunnerGrant.scope_offer(actor)
      inherited = offer if %i[account_wide user_private].include?(offer)
      RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
    end

    def await_active(status)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RhoDaemon::READY_TIMEOUT
      loop do
        document = status.call
        return document if finished?(document)
        raise "the daemon never finished its ceremony; last seen #{document.inspect}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep RhoDaemon::POLL
      end
    end

    def finished?(document)
      return false unless document["state"] == "active"

      connection = document["connection"]
      connection.nil? || connection["phase"] == "active"
    end
  end
end
