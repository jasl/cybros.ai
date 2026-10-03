require "fileutils"
require "json"
require_relative "evals/world_log"
require_relative "secret_hygiene"

module E2E
  # A failed world retains complete redacted logs with a manifest, plus `sealed_requests.json`
  # containing the latest sealed requests and host events. Each request names the loop/task or
  # invocation that sealed it. Every process writes its own Rails log under the run root, so
  # diagnosis survives world teardown and does not depend on the checkout's shared log rotation.
  #
  # Pure over paths and documents: the world names its sources and reads
  # the sealed documents (`NexusServer::SEALED_REQUESTS`, a `bin/rails
  # runner` script); the harness test hands both in.
  module FailureDump
    SEALED_FILE = "sealed_requests.json".freeze

    module_function

    # Answers the files written. `sealed:` is the list of documents the
    # world read (`[]` when it could not); the copy of the logs is
    # `WorldLog`'s, `redact:` the world's own redaction.
    def write(into:, sources:, sealed: [], redact: SecretHygiene.method(:redact))
      FileUtils.mkdir_p(into)
      written = Evals::WorldLog.copy(into: into, sources: sources, redact: redact)
      target = File.join(into, SEALED_FILE)
      File.write(target, redact.call("#{JSON.pretty_generate(Array(sealed))}\n"), encoding: Encoding::UTF_8)
      written + [target]
    end
  end
end
