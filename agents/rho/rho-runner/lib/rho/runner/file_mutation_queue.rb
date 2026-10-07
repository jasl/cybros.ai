module Rho
  class Runner
    # Serializes mutations PER FILE, so two tasks editing the same path
    # cannot interleave while different files stay fully parallel.
    #
    # RUNNER-SCOPED, never a module global: the runner owns the file
    # resource, so the queue travels with the runner — which is exactly what
    # lets a second runner exist on another machine without either knowing.
    # (pi keeps a module-level Map, which does not survive that.)
    #
    # Keys are symlink-resolved realpaths; a not-yet-existing file resolves
    # its nearest existing parent and appends the missing suffix, so
    # `write` and `edit` of the same new path still serialize.
    #
    # Acquisition polls cooperatively rather than blocking, so a cancelled
    # task is not stranded behind another file's mutation until the pool's
    # grace expires.
    class FileMutationQueue
      LOCK_POLL_SECONDS = 0.01
      Entry = Struct.new(:mutex, :waiters)

      def initialize
        @registration = Mutex.new
        @entries = {}
      end

      def with_lock(path)
        key = queue_key(path)
        entry = @registration.synchronize do
          found = (@entries[key] ||= Entry.new(Mutex.new, 0))
          found.waiters += 1
          found
        end

        locked = false
        begin
          until locked
            ExecutionContext.current&.raise_if_cancelled!
            locked = entry.mutex.try_lock
            sleep(LOCK_POLL_SECONDS) unless locked
          end
          ExecutionContext.current&.raise_if_cancelled!
          yield
        ensure
          entry.mutex.unlock if locked
          @registration.synchronize do
            entry.waiters -= 1
            @entries.delete(key) if entry.waiters.zero?
          end
        end
      end

      def queue_key(path)
        expanded = File.expand_path(path)
        File.realpath(expanded)
      rescue Errno::ENOENT, Errno::ENOTDIR
        missing_path_key(expanded)
      end

      def missing_path_key(expanded)
        suffix = []
        current = expanded

        loop do
          parent = File.dirname(current)
          return expanded if parent == current

          suffix.unshift(File.basename(current))
          return File.join(File.realpath(parent), *suffix)
        rescue Errno::ENOENT, Errno::ENOTDIR
          current = parent
        end
      end
    end
  end
end
