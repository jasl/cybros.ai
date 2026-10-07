require_relative "dev"

# Explicit path loading evaluates this file in an anonymous module. Export
# the same factory the gem feature exposes under Rho::Dev.
Dev = ::Rho::Dev
