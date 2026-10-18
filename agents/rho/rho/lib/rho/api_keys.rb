module Rho
  # The imported runtime planes while they wait for the existing connection
  # installer. They have no refresh token, expiry, or rotation counter.
  class APIKeys
    include CybrosAgent::Redacted

    FIELDS = %w[access_token executor_access_token runner_access_token].freeze

    attr_reader :access_token, :executor_access_token, :runner_access_token

    def self.parse(document, mode:)
      fields = document.to_h.transform_keys(&:to_s)
      raise ConnectionError, "Unknown API key fields" unless (fields.keys - FIELDS).empty?

      required = mode == "runner" ? %w[executor_access_token] : %w[access_token executor_access_token]
      required << "runner_access_token" if mode == "full"
      unless fields.keys.sort == required.sort
        raise ConnectionError, "Mode #{mode} requires #{required.join(", ")}"
      end
      tokens = fields.transform_values { |value| value.to_s.strip }
      raise ConnectionError, "API keys must not be empty" if tokens.values.any?(&:empty?)

      new(**tokens.transform_keys(&:to_sym))
    end

    def initialize(access_token: nil, executor_access_token:, runner_access_token: nil)
      @access_token = access_token
      @executor_access_token = executor_access_token
      @runner_access_token = runner_access_token
    end

    def member_plane? = !@access_token.nil?
    def executor_plane? = !@executor_access_token.nil?
    def runner_plane? = !@runner_access_token.nil?
    def runner_half = self.class.new(executor_access_token: @runner_access_token)
    def to_h = { "access_token" => @access_token, "executor_access_token" => @executor_access_token,
      "runner_access_token" => @runner_access_token }.compact
    def inspect = redacted(hidden: FIELDS)
    alias_method :to_s, :inspect
  end
end
