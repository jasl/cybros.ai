require "cybros_agent"

module Rho
  # ONE OBJECT CARRYING UP TO THREE PLANES. The SDK's `Credentials::OAuth` is ONE refresh
  # lineage — one refresh token, one document, one store lock — and a combined consume
  # mints TWO families, so the daemon's `about` is this holder: the agent lineage (member
  # + executor transport) and the runner lineage (the in-process runner's transport), each
  # an SDK OAuth that rotates on its own.
  #
  # Every daemon edge keys on THIS object's identity (the lineage's CAS),
  # which is why the runner half is a SLOT and never a second `about`: a
  # restore keeps the live runner lineage by object identity, a runner-plane
  # loss drops one half without moving the agent's. The two slot writers do
  # no IO, so the lineage may run them under its monitor.
  class Credentials
    include CybrosAgent::Redacted

    attr_reader :agent, :runner

    def initialize(agent: nil, runner: nil)
      @agent = agent
      @runner = runner
    end

    def agent? = !@agent.nil?
    def runner? = !@runner.nil?

    def lineages = [@agent, @runner].compact

    # The agent lineage's two planes, as every reader named them before the
    # runner half existed.
    def member_credential = require_agent.member_credential
    def executor_credential = require_agent.executor_credential

    # The in-process runner's transport credential: the runner lineage's
    # executor half (branch B's shape).
    def runner_credential = require_runner.executor_credential

    def member_plane? = agent? && @agent.member_plane?
    def executor_plane? = agent? && @agent.executor_plane?
    def runner_plane? = runner? && @runner.executor_plane?

    # The rotation counter of the lineage a plane rides; nil for a plane no
    # lineage here carries.
    def rotation(plane)
      lineage_for(plane)&.rotation
    end

    def attach_runner(oauth)
      @runner = oauth
      self
    end

    # Answers the lineage dropped (nil when there was none), so the caller
    # can retire what rode on it.
    def drop_runner
      previous = @runner
      @runner = nil
      previous
    end

    def inspect = redacted(agent: agent?, runner: runner?, hidden: [])
    alias_method :to_s, :inspect

    private

      def lineage_for(plane)
        plane == :runner_transport ? @runner : @agent
      end

      def require_agent
        @agent || raise(CybrosAgent::Credentials::PlaneUnavailable, "this connection has no agent credential")
      end

      def require_runner
        @runner || raise(CybrosAgent::Credentials::PlaneUnavailable, "this connection has no runner credential")
      end
  end
end
