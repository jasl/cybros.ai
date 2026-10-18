module CybrosAgent
  module Credentials
    # The credential store, as a port the application implements.
    #
    # This gem owns the OAuth rotation *protocol* — persist-before-use,
    # ambiguous-outcome latching, and in-process serialization (see OAuth).
    # It deliberately owns no storage: an
    # SDK that writes files imposes one storage model on every consumer, and
    # the next SDKs are not Ruby, so a flock/fsync protocol would not port
    # while the rules above must.
    #
    # A store is any object answering five messages. It is five and not more
    # because that is what OAuth was measured to use — the surface is a
    # measurement, not a design (`delete` joined with OAuth#revoke):
    #
    #   read                -> Hash | nil   the persisted document, nil if none
    #   write(document)     -> anything     durably replace it
    #   delete              -> anything     forget it; a later read answers nil
    #   with_lock { ... }   -> block value  serialize a caller's own
    #                                       read-modify-write in this process
    #   description         -> String       what to call this store in an
    #                                       error a human reads
    #
    # `description` and not `path`: a keychain or a secret manager has no path
    # to return, and a port that leaks the filesystem is not a port.
    #
    # What an implementation must guarantee, because the protocol above is
    # built on it:
    #
    #   `with_lock` excludes sibling callers inside one application process.
    #   Process ownership is an application lifecycle concern; rho supplies a
    #   daemon-lifetime Home lock rather than creating a second lock protocol
    #   around every credential operation.
    #
    #   `write` either publishes the document or raises. A partially written
    #   document is never observable by `read`.
    #
    #   `write` carries its own bound and never waits on a network. The
    #   protocol runs its commit — the write that lands a freshly rotated
    #   pair — inside an interrupt mask, because a kill severing a rotation
    #   from its persist strands a spent token as the only one on disk (see
    #   OAuth#rotate!). A masked section cannot be killed, so a write that
    #   can hang indefinitely turns an orderly shutdown into `kill -9`. A
    #   store fronting something remote must impose its own deadline and
    #   raise, rather than wait.
    #
    #   `read` returns what `write` was given, through a round trip that
    #   preserves JSON scalar types and string keys.
    module Store
      # Marks the one outcome the protocol must tell apart from a failed
      # write: the document IS stored and readable, and only the durability of
      # the write is unconfirmed. The caller's next move differs — after this
      # the credential in memory is live and MUST keep being used, because
      # re-running the exchange would present a token the server has already
      # spent. Every other failure of `write` means nothing was published.
      #
      # A module, not a class, so an adapter can raise an error that belongs to
      # its OWN tree and still be recognized here: rho's file store raises a
      # `Rho::StateError`, which a rho caller rescuing its own errors must keep
      # catching, while `rescue Store::Published` still sees it. Structural,
      # like the port itself.
      module Published; end
    end
  end
end
