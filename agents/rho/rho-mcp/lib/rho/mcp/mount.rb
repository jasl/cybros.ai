module Rho
  module Mcp
    # Prepared registrations retain their exact connections. Publication only
    # changes future callers; the host retires an old mount after its calls end.
    class Mount
      attr_reader :entries, :ledger, :previous

      def initialize(entries:, ledger:)
        @entries, @ledger = entries, ledger
        @previous = nil
        @closed = false
      end

      def activate
        @previous = Mcp.activate(self)
      end

      def close
        return if @closed

        @closed = true
        Mcp.retire(self)
      ensure
        @previous = nil
      end

      def closed? = @closed

      def connections = entries.values.filter_map(&:connection)

      def documents_for(serves)
        entries.values.flat_map { |entry| entry.row.serves == serves && entry.documents ? entry.documents.entries : [] }
      end

      def load_document(serves, name, env)
        entry = entries.values.find { |candidate| candidate.announces?(serves, name) }
        return nil if entry.nil?

        document = entry.documents.find(name)
        if document.prompt?
          entry.connection.load_prompt(document.raw_name, name: name, env: env)
        else
          entry.connection.load_resource(document.uri, name: name, env: env)
        end
      end
    end
  end
end
