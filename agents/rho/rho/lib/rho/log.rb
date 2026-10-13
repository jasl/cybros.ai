require "cybros_agent"
require "fileutils"
require "time"

module Rho
  # The structured `event=` logger. One line per fact:
  #
  #   2027-01-15T08:00:00Z level=info event=connection.phase from=idle to=pending
  #
  # A daemon's only real output is this file, and it is read after the
  # process is gone — so the format is fixed, greppable, and impossible for a
  # field value to break out of. Two rules earn their place:
  #
  #   Values are quoted and escaped when they need it. A human-written client
  #   name containing a space would otherwise become two fields, and a value
  #   containing a newline would forge an entire second line.
  #
  #   Secrets never reach the stream, whatever key they arrive under. A log
  #   outlives the process that wrote it, so a credential in one is a
  #   credential handed to every later reader. Both the key's name and the
  #   value's own shape are checked, because a token can be passed under any
  #   name at all.
  #
  # Rotation is deliberately not here: `logrotate` and its kin already do it
  # correctly, and a size cap invented in-process would be a second, worse
  # implementation. The file is opened append-only and 0600.
  class Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    # A key whose value is a credential by name is the SDK's ONE table
    # (`CybrosAgent::Redaction::SECRET_KEY`), as the value's shape is its
    # pattern — two homes drifted once (sec-6: `api_key`, `authorization`
    # and `cookie` were printed here).
    NIL_VALUE = "-".freeze
    FILE_MODE = 0o600

    # A path rather than an IO, because the mode matters and every caller
    # would otherwise have to remember it.
    def self.to_file(path, level: :info, clock: -> { Time.now })
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      io = File.open(path, File::WRONLY | File::APPEND | File::CREAT, FILE_MODE)
      io.sync = true
      File.chmod(FILE_MODE, path)
      new(io: io, level: level, clock: clock)
    end

    def initialize(io:, level: :info, clock: -> { Time.now })
      raise ArgumentError, "unknown log level #{level.inspect}" unless LEVELS.key?(level.to_sym)

      @io = io
      @level = level.to_sym
      @threshold = LEVELS.fetch(@level)
      @clock = clock
      @mutex = Mutex.new
    end

    LEVELS.each_key do |name|
      define_method(name) { |event, **fields| write(name, event, fields) }
    end

    # The same stream with standing fields on every line — how a runner's
    # claim line names the address it serves without the runner
    # gem learning what an address is.
    def tagged(**fields) = Tagged.new(self, fields)

    class Tagged
      def initialize(log, fields)
        @log = log
        @fields = fields
      end

      LEVELS.each_key do |name|
        define_method(name) { |event, **fields| @log.public_send(name, event, **fields, **@fields) }
      end

      def tagged(**fields) = Tagged.new(@log, @fields.merge(fields))

      def inspect = "#<Rho::Log::Tagged #{@fields.inspect}>"
      alias_method :to_s, :inspect
    end

    def close
      @io.close unless @io.closed?
      nil
    end

    def inspect = "#<Rho::Log level=#{@level}>"
    alias_method :to_s, :inspect

    private

      def write(level, event, fields)
        return nil if LEVELS.fetch(level) < @threshold

        line = +"#{@clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ")} level=#{level} event=#{event}"
        fields.each { |key, value| line << " #{key}=#{render(key, value)}" }
        # One write of one whole line: two threads must never interleave
        # halves of two facts.
        @mutex.synchronize { @io.write("#{line}\n") }
        nil
      end

      def render(key, value)
        return NIL_VALUE if value.nil?
        return CybrosAgent::Redaction::REPLACEMENT if CybrosAgent::Redaction::SECRET_KEY.match?(key.to_s)

        text = value.is_a?(Exception) ? "#{value.class}: #{value.message}" : value.to_s
        text = CybrosAgent::Redaction.call(text)
        # The marker is unquoted wherever it stands alone, so one grep for
        # `=[REDACTED]` finds every scrubbed field regardless of which rule
        # scrubbed it.
        return text if text == CybrosAgent::Redaction::REPLACEMENT

        bare?(text) ? text : quote(text)
      end

      def bare?(text) = /\A[[:alnum:]][\w.:@\/+-]*\z/.match?(text)

      def quote(text) = text.dump
  end
end
