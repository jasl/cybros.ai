module Rho
  # The old follower cache also held conversation policy. Claim that source
  # for one Profile before any Nexus IO, then retire it only after every
  # conversation has an authoritative policy (or is confirmed gone).
  # Partial progress lives in memory: after a crash Nexus wins over the same
  # immutable defaults, so no second local business document is needed.
  class LegacyHostPolicies
    POLICY_KEYS = %w[model compose notes].freeze

    def initialize(home:, user_public_id:)
      @legacy = File.join(home.tmp_root, "hosts.json")
      @source = File.join(home.tmp_root, "hosts.#{user_public_id}.migrating.json")
      @imported = File.join(home.tmp_root, "hosts.#{user_public_id}.imported.json")
      @rows = nil
      @pending = []
      @claimed = false
    end

    def rows
      claim unless @rows
      @rows
    end

    def policy(host_public_id)
      row = rows.find do |entry|
        entry.fetch("host_type") == "conversation" && entry.fetch("host_public_id") == host_public_id
      end
      row&.slice(*POLICY_KEYS)
    end

    def complete(host_public_id)
      rows
      @pending.delete(host_public_id)
      retire if @claimed && @pending.empty?
      nil
    end

    private

      def claim
        StateFile.new(@legacy).with_lock do |file|
          @rows = []
          if File.file?(@source)
            @rows = read_rows(StateFile.new(@source).read)
          elsif !File.exist?(@imported) && File.file?(@legacy)
            candidates = read_rows(file.read)
            return unless candidates.any? { |row| POLICY_KEYS.any? { |key| row.key?(key) } }

            File.rename(@legacy, @source)
            @rows = candidates
          else
            return
          end
          @claimed = true
          @pending = @rows.filter_map do |row|
            row.fetch("host_public_id") if row.fetch("host_type") == "conversation"
          end
          flush
          retire if @pending.empty?
        end
      end

      def read_rows(document)
        document.fetch("hosts").map(&:to_h)
      end

      def retire
        File.rename(@source, @imported)
        @claimed = false
        flush
      end

      def flush
        File.open(File.dirname(@source), File::RDONLY) { |directory| directory.fsync }
      rescue *StateFile::DIRECTORY_FSYNC_UNSUPPORTED
        nil
      rescue SystemCallError => error
        raise StateError, "host policy migration source rename could not be flushed (#{error.class})"
      end
  end
end
