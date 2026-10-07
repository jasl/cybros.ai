require "fileutils"
require "json"

module Rho
  module AcpClient
    # THE CAPTURE: every message both ways
    # between rho and one child, one JSON object a line, appended to
    # `<artifacts_dir>/acp/<agent>-<session>.jsonl` under the work dir
    # keyed by root — never the project — every string in it through the
    # row's redaction. `out` is what rho sent, `in` what the child sent,
    # `note` a fact of rho's own (a permission decision, a kill). The file
    # rides the result as a `resource_link` (`rho fetch` reads it) and
    # `rho acp-agents logs SESSION` prints it. A probe passes no capture
    # and writes nothing.
    class Capture
      DIRECTORY = "acp".freeze

      attr_reader :path

      def self.path_for(artifacts_dir, agent, session)
        File.join(artifacts_dir, DIRECTORY, "#{agent}-#{session}.jsonl")
      end

      def initialize(path, redact:, clock: -> { Time.now })
        @path = path
        @redact = redact
        @clock = clock
        @lock = Mutex.new
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        @io = File.open(path, "a", encoding: Encoding::UTF_8)
        @io.sync = true
      end

      def line(direction, message, **fields)
        record = { "at" => @clock.call.utc.iso8601(3), "dir" => direction.to_s }
        record.merge!(@redact.structure(fields.transform_keys(&:to_s)))
        record["message"] = @redact.structure(message) unless message.nil?
        write(record)
      end

      def note(event, **fields) = line(:note, nil, event: event, **fields)

      def close
        @lock.synchronize do
          @io.close unless @io.closed?
        end
        nil
      end

      private

        def write(record)
          text = "#{JSON.generate(record)}\n"
          @lock.synchronize do
            return nil if @io.closed?

            @io.write(text)
          end
          nil
        rescue IOError, SystemCallError, JSON::GeneratorError
          nil
        end
    end
  end
end
