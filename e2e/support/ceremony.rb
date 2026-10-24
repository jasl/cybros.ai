require_relative "runner_grant"

module E2E
  # Complete the published SDK or application ceremony through its browser page.
  # Agent connections and Human login use the agent page; independent Runner
  # registration uses the machine page and its scope selection. The published
  # branch determines the page, independently of the peer implementation.
  # When supplied, status waits for the owning application to become active.
  module Ceremony
    RUNNER_SENTENCE = "Also runs as a runner on that machine".freeze
    AGENT_SUBJECT = "agent program".freeze
    BRANCHES = %w[agent runner login].freeze

    # What `RunnerGrant` reads off an independent executor authorization: the
    # grant is branch B for a `runner`-kind registration.
    Authorization = Data.define(:verification_uri_complete, :user_code, :branch, :executor_kind)

    module_function

    def confirm(actor:, started:, status: nil)
      branch = started.fetch("branch") { raise ArgumentError, "the ceremony published no branch: #{started.inspect}" }
      raise ArgumentError, "unknown ceremony branch #{branch.inspect}" unless BRANCHES.include?(branch)

      if branch == "runner"
        confirm_runner_page(actor, started)
      else
        confirm_agent_page(actor, started, runner_sentence: false, login: branch == "login")
      end
      await_active(status) if status
    end

    # The agent page as every rho journey walked it: the pre-filled code,
    # the subject, the code again, Connect, the settled sentence.
    def confirm_agent_page(actor, started, runner_sentence:, login: false)
      page = actor.page
      actor.visit(started.fetch("verification_uri_complete"))
      page.assert_selector(:field, "Device code", with: started.fetch("user_code"))

      page.click_button "Continue"
      page.assert_text("Connect #{AGENT_SUBJECT}")
      page.assert_text(started.fetch("user_code"))
      assert_runner_sentence(page, runner_sentence)
      page.assert_text("Your existing Agent and Runner connection will keep running.") if login

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
      inherited = offer if RunnerGrant::SCOPE_BADGES.key?(offer)
      RunnerGrant.connect_in_browser(actor: actor, authorization: authorization,
        account_wide: offer == :selector, existing_runner_scope: inherited)
    end

    def await_active(status)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        document = status.call
        return document if finished?(document)
        raise "the daemon never finished its ceremony; last seen #{document.inspect}" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.2
      end
    end

    def finished?(document)
      return false unless document["state"] == "active"

      connection = document["connection"]
      connection.nil? || connection["phase"] == "active"
    end
  end
end
