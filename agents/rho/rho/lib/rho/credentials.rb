require "cybros_agent"

module Rho
  # A connection holds one owner: application planes or standalone machine transport.
  class Credentials
    include CybrosAgent::Redacted

    attr_reader :agent, :runner

    def initialize(agent: nil, runner: nil)
      @agent = agent
      @runner = runner
    end

    def self.load(identity:, authority:, clock: -> { Time.now })
      new(
        agent: (CybrosAgent::Credentials.load(authority: authority, store: identity.vault, clock: clock) unless identity.runner_mode?),
        runner: (CybrosAgent::Credentials.load(authority: authority, store: identity.runner_vault, clock: clock) if identity.runner_mode?)
      )
    end

    def agent? = !@agent.nil?
    def runner? = !@runner.nil?

    def lineages = [@agent, @runner].compact

    def member_credential = require_agent.member_credential
    def executor_credential = require_agent.executor_credential

    def runner_credential = require_runner.executor_credential

    def member_plane? = agent? && @agent.member_plane?
    def executor_plane? = agent? && @agent.executor_plane?
    def runner_plane? = runner? && @runner.executor_plane?

    # The rotation counter of the lineage a plane rides; nil for a plane no
    # lineage here carries.
    def rotation(plane)
      owner = lineage_for(plane)
      owner.rotation if owner&.refreshable?
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
