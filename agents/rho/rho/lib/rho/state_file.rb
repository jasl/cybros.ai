require "cybros_agent"
require "fileutils"
require "monitor"
require "json"
require "securerandom"

module Rho
  # A private JSON document with crash-safe replacement. The daemon's
  # lifetime-held Home lock is the process boundary; StateFile only
  # coordinates callers inside that process.
  class StateFile
    # The document is published, but flushing its directory entry failed.
    # A rotating credential must keep the new in-memory pair and never retry
    # the already-spent refresh token.
    class PublishedError < StateError
      include CybrosAgent::Credentials::Store::Published
    end

    PRIVATE_DIRECTORY_MODE = 0o700
    PRIVATE_FILE_MODE = 0o600
    DIRECTORY_FSYNC_UNSUPPORTED = [Errno::EINVAL, Errno::ENOTSUP, Errno::EOPNOTSUPP].uniq.freeze

    # Monitor raises rather than waiting when another fiber on the same thread
    # owns it. Under a scheduler, a short yielding retry gives the owner room
    # to finish; without one, failing is the only non-deadlocking answer.
    class InProcessLock
      WAIT_INTERVAL = 0.005

      def initialize
        @monitor = Monitor.new
        @owner_thread = nil
        @depth = 0
      end

      def synchronize
        acquired = false
        acquire
        acquired = true
        yield
      ensure
        release if acquired
      end

      private

        def acquire
          until @monitor.try_enter
            if Fiber.scheduler.nil? && @owner_thread.equal?(Thread.current)
              raise ThreadError, "state file lock is already owned by another fiber on this thread"
            end

            sleep WAIT_INTERVAL
          end
          @owner_thread = Thread.current
          @depth += 1
        end

        def release
          @depth -= 1
          @owner_thread = nil if @depth.zero?
          @monitor.exit
        end
    end
    private_constant :InProcessLock

    @locks = {}
    @locks_mutex = Mutex.new

    class << self
      private

        def lock_for(path)
          @locks_mutex.synchronize { @locks[path] ||= InProcessLock.new }
        end
    end

    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path)
      @lock = StateFile.send(:lock_for, @path)
    end

    def description = @path

    def read
      synchronized { load_document }
    end

    def write(document)
      synchronized { store_document(document) }
    end

    def with_lock
      synchronized { yield self }
    end

    # Used for identity/binding files whose first published owner wins. The
    # link is the filesystem's ordinary create-if-absent primitive; the Home
    # lock already makes competing rho processes unreachable.
    def create_once(document)
      synchronized do
        write_through_temp(document) do |temp, _canonical|
          File.link(temp, @path)
          true
        rescue Errno::EEXIST
          false
        end
      end
    end

    def delete
      synchronized do
        File.unlink(@path)
        fsync_directory
      rescue Errno::ENOENT
        nil
      end
      nil
    end

    def inspect
      "#<Rho::StateFile path=#{@path.inspect}>"
    end
    alias_method :to_s, :inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    private

      def synchronized(&)
        @lock.synchronize(&)
      end

      def load_document
        return nil unless File.file?(@path)

        verify_private_file
        # BY NAME, not the process default: a machine with no LANG reads
        # US-ASCII, and a remembered run's seed carries UTF-8 (the em-dash
        # in the acceptance paragraph) — the daemon must not depend on
        # exe/rho having set the default before it reads its own state.
        raw = File.read(@path, encoding: Encoding::UTF_8)
        return nil if raw.empty?

        JSON.parse(raw).to_h
      rescue JSON::ParserError
        raise StateError, "state file #{@path} is not valid JSON (corrupt or hand-edited)"
      rescue NoMethodError, TypeError
        raise StateError, "state file #{@path} takes a JSON object"
      end

      def store_document(document)
        verify_private_file if File.file?(@path)

        write_through_temp(document) do |temp, canonical|
          File.rename(temp, @path)
          canonical
        end
      end

      def write_through_temp(document)
        prepare_directory
        temp = temporary_path
        serialized = JSON.pretty_generate(normalize_document(document))
        canonical = JSON.parse(serialized)

        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, PRIVATE_FILE_MODE) do |file|
          file.write(serialized)
          file.write("\n")
          file.flush
          file.fsync
        end
        result = yield(temp, canonical)
        begin
          fsync_directory
        rescue SystemCallError => error
          raise PublishedError,
            "state file #{@path} is published but its directory entry could not be flushed " \
            "(#{error.class}); the document is written — do not retry"
        end
        result
      ensure
        FileUtils.rm_f(temp) if temp
      end

      def normalize_document(document)
        document.to_h
      rescue NoMethodError, TypeError
        raise StateError, "state file #{@path} takes a JSON object"
      end

      def prepare_directory
        directory = File.dirname(@path)
        if File.directory?(directory)
          verify_private_directory(directory)
        else
          FileUtils.mkdir_p(directory, mode: PRIVATE_DIRECTORY_MODE)
          File.chmod(PRIVATE_DIRECTORY_MODE, directory)
        end
      end

      def verify_private_directory(directory)
        stat = File.stat(directory)
        raise StateError, "state directory #{directory} must be owned by the current user" unless stat.owned?

        mode = stat.mode & 0o777
        return if mode == PRIVATE_DIRECTORY_MODE

        raise StateError,
          "state directory #{directory} must be private (mode 0700), got #{format("%04o", mode)}"
      end

      def verify_private_file
        stat = File.stat(@path)
        raise StateError, "state file #{@path} must be owned by the current user" unless stat.owned?

        mode = stat.mode & 0o777
        return if (mode & 0o077).zero?

        raise StateError,
          "state file #{@path} must be private to its owner (mode 0600), got #{format("%04o", mode)}"
      end

      def fsync_directory
        File.open(File.dirname(@path), File::RDONLY) { |directory| directory.fsync }
        nil
      rescue *DIRECTORY_FSYNC_UNSUPPORTED
        nil
      end

      def temporary_path
        "#{@path}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
      end
  end
end
