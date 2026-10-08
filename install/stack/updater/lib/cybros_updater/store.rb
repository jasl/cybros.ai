module CybrosUpdater
  class Store
    LOG_LIMIT = 1024 * 1024
    RECEIPT_LIMIT = 20

    def initialize(directory)
      @directory = directory
      FileUtils.mkdir_p(directory, mode: 0o700)
      @lock = File.open(File.join(directory, "lock"), File::RDWR | File::CREAT, 0o600)
      unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
        @lock.close
        raise Error.new("updater_unavailable", "Another updater owns this installation.")
      end
    end

    def load
      path = File.join(@directory, "state.json")
      if File.exist?(path)
        JSON.parse(File.read(path))
      else
        { "installed" => nil, "candidate" => nil, "preflight" => nil, "receipts" => [] }
      end
    end

    def save(installed:, candidate:, preflight:, receipts:)
      document = { "installed" => installed&.to_h, "candidate" => candidate&.to_h, "preflight" => preflight&.to_h, "receipts" => receipts.map(&:to_h) }
      atomic_write(File.join(@directory, "state.json"), JSON.generate(document) + "\n")
    end

    def append_log(id, text)
      path = log_path(id)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        remaining = LOG_LIMIT - file.size
        if remaining.positive?
          message = text.encode("UTF-8", invalid: :replace, undef: :replace)
          message = message.byteslice(0, remaining).scrub
          file.write(message.byteslice(0, remaining))
          file.flush
          file.fsync
        end
        cursor(file.size)
      end
    end

    def log(id, offset:, limit:)
      path = log_path(id)
      if File.exist?(path)
        File.open(path, "rb") do |file|
          if offset > file.size
            raise Error.new("invalid_request", "Log cursor is beyond the available log.", status: 400)
          end
          file.seek(offset)
          # JSON may expand a control byte to six bytes. Leave space for its
          # envelope and receipt even for maximally escaped command output.
          bytes = file.read([limit, RESPONSE_LIMIT / 8].min).to_s
          next_cursor = cursor(file.pos)
          entries = bytes.empty? ? [] : [{ "cursor" => next_cursor, "text" => bytes.force_encoding("UTF-8").scrub }]
          { "entries" => entries, "next_cursor" => next_cursor }
        end
      else
        { "entries" => [], "next_cursor" => cursor(0) }
      end
    end

    def prune(ids)
      ids.each { |id| FileUtils.rm_f(log_path(id)) }
    end

    def close
      @lock.close
    end

    def atomic_write(path, contents, owner: nil)
      temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.chown(owner.uid, owner.gid) if owner
        file.write(contents)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      # A failure after rename is not permission to replay a deployment effect.
      File.open(File.dirname(path), File::RDONLY, &:fsync)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    private

    def log_path(id) = File.join(@directory, "#{id}.log")
    def cursor(offset) = Base64.strict_encode64(offset.to_s)
  end
end
