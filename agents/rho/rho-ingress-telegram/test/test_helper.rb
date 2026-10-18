$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/ingress-telegram"
require "minitest/autorun"
require_relative "support/fake_telegram"
require_relative "support/store"
