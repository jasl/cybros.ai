$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cybros_agent"

require "minitest/autorun"

require_relative "support/fake_transport"
