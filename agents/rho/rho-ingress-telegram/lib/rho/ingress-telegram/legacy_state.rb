module Rho
  module IngressTelegram
    # Claim an existing local migration source for exactly one Profile before
    # any Nexus IO. Only that Profile can resume it after an interrupted import.
    # The source is renamed, never copied or rewritten as ongoing local state.
    class LegacyState
      def initialize(home:, user_public_id:)
        directory = File.join(home.root, "telegram")
        @legacy = File.join(directory, "state.json")
        @source = File.join(directory, "state.#{user_public_id}.migrating.json")
        @imported = File.join(directory, "state.#{user_public_id}.imported.json")
        @claimed = @checked = false
      end

      def claim
        return if @checked

        if File.file?(@source)
          @claimed = true
        elsif !File.exist?(@imported) && File.file?(@legacy)
          Rho::StateFile.new(@legacy).read
          File.rename(@legacy, @source)
          @claimed = true
        end
        flush if @claimed
        @checked = true
      end

      def call
        claim
        Rho::StateFile.new(@source).read if @claimed
      end

      # A successfully returned store document confirms Nexus is authoritative,
      # including a prior import whose response was lost before process death.
      def complete
        return unless @claimed

        File.rename(@source, @imported)
        @claimed = false
        flush
      end

      private

        def flush
          File.open(File.dirname(@source), File::RDONLY) { |directory| directory.fsync }
        rescue *Rho::StateFile::DIRECTORY_FSYNC_UNSUPPORTED
          nil
        rescue SystemCallError => error
          raise Rho::StateError, "telegram: migration source rename could not be flushed (#{error.class})"
        end
    end
  end
end
