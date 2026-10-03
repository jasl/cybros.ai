require "monitor"

module E2E
  # Best-effort diagnostic hygiene for the isolated E2E world. Its synthetic credentials are public
  # test inputs, not a security boundary; registration keeps failure output readable and guarded
  # callers may suppress screenshots while a credential remains in the DOM.
  module SecretHygiene
    REPLACEMENT = "[REDACTED]".freeze
    # Every Cybros bearer family the harness can meet: member/platform access
    # tokens, API Session bearers, refresh/device/recovery codes.
    BEARER_PATTERN = /(?:sk|rt|dc|rc)-cybros-[a-z0-9-]*v1-\S+/

    @secrets = []
    @reveal_depth = 0
    @monitor = Monitor.new

    class << self
      # Remembers one raw secret for redaction. Returns it so registration
      # can wrap the capture site.
      def register(secret)
        return secret if secret.nil? || secret.empty?

        @monitor.synchronize { @secrets |= [secret.dup.freeze] }
        secret
      end

      def redact(text)
        return "" if text.nil?

        scrubbed = @monitor.synchronize do
          @secrets.reduce(text.to_s) { |output, secret| output.gsub(secret, REPLACEMENT) }
        end
        scrubbed.gsub(BEARER_PATTERN, REPLACEMENT)
      end

      # Wraps the window in which a raw secret is present in a browser DOM.
      # On a failure inside the window the guard deliberately stays closed:
      # the process can no longer prove the secret left the page, so every
      # later screenshot is refused rather than risked.
      def during_reveal
        @monitor.synchronize { @reveal_depth += 1 }
        result = yield
        @monitor.synchronize { @reveal_depth -= 1 }
        result
      end

      def reveal_open?
        @monitor.synchronize { @reveal_depth.positive? }
      end

      # Guarded callers suppress a failure screenshot while their reveal
      # window remains open; this is diagnostic hygiene, not secret handling.
      def save_screenshot(actor, path)
        return if actor.nil?

        if reveal_open?
          warn "E2E screenshot skipped: a secret reveal window is open"
        else
          actor.save_screenshot(path)
        end
      rescue StandardError => error
        warn "Could not save E2E browser screenshot: #{error.class}: #{redact(error.message)}"
      end
    end
  end
end
