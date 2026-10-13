module Rho
  class Error < StandardError; end

  # The operator asked for something rho cannot act on: an address that is not
  # an absolute HTTP URL, or an identifier that cannot be a path segment.
  class ConfigurationError < Error; end

  # A connection ceremony could not be carried through — it produced no
  # credential for a required bootstrap plane, or a caller drove the
  # phases out of order.
  class ConnectionError < Error; end

  # A state file is wrong in a way the caller cannot fix: not JSON, not an
  # object, readable by others, or its lock lost while held.
  class StateError < Error; end

  # What is on disk about an existing connection cannot be trusted: it belongs
  # to a different Nexus, or it is incomplete. Refused rather than adopted,
  # because adopting another home's credentials is worse than asking
  # for a fresh ceremony.
  class StoredConnectionError < Error; end

  # Another daemon already owns this home. Raised rather than queued: two
  # daemons on one home would write the same vault and redeem the
  # same rotating refresh token, which revokes the whole connection.
  class AlreadyRunning < Error; end
end
