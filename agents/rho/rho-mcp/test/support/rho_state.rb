# RHO'S STATE FILE, FOR THE OAUTH SUITE:
# the credential store is ONE `Rho::StateFile` per server — rho's own
# class, the vault's — and the pins on it (a 0644 file refused, a
# `PublishedError` keeping the pair) need the real one, not a double.
# rho-mcp's bundle carries no `rho` (an extension gem depends on the
# runner alone), so the two files are loaded from the sibling checkout
# by path: `rho/errors` (`Rho::Error`, `Rho::StateError`) and
# `rho/state_file`. With `Rho::Error` defined, `Commands.refuse` raises
# it — as it does in every process that has these verbs.
$LOAD_PATH.unshift File.expand_path("../../../rho/lib", __dir__)
require "rho/errors"
require "rho/state_file"
