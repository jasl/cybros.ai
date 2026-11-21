require "cybros_agent"
require "json"
require "fileutils"
require "tempfile"
require "uri"
require "optparse"
require "io/console"

require_relative "cybros_control/version"

module CybrosControl
  def self.login_with_device(sessions, output)
    sessions.create_with_device do |authorization|
      output.puts("Open #{authorization.verification_uri_complete} in your browser.")
      output.puts("Compare the code #{authorization.user_code}, then approve this terminal.")
    end
  end

  class Error < StandardError; end
  class UsageError < Error; end
  class Cancelled < Error; end
end

require_relative "cybros_control/config"
require_relative "cybros_control/prompt"
require_relative "cybros_control/model_fields"
require_relative "cybros_control/setup"
require_relative "cybros_control/cli"
