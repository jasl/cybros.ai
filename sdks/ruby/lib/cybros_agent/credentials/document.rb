module CybrosAgent
  module Credentials
    # The common persisted envelope is validated once before its closed
    # authentication kind selects the payload. Diagnostics name fields only.
    module Document
      VERSION = 2

      def self.read(store)
        document = store.read
        return if document.nil?

        where = "credential store #{store.description}"
        document = Hash.try_convert(document)
        raise StoreError, "#{where} does not contain a credential document" if document.nil?
        raise StoreError, "#{where} is not format version #{VERSION}" unless document["version"] == VERSION

        case document["authentication_kind"]
        when "oauth"
          OAuth::Document.from_h(document, where: where)
        when "api_key"
          APIKey::Document.from_h(document, where: where)
        else
          raise StoreError, "#{where} has no supported authentication kind"
        end
      end

      def self.text(document, field, message)
        value = document.fetch(field).to_str
        raise StoreError, message if value.empty?

        value
      rescue KeyError, NoMethodError, TypeError
        raise StoreError, message, cause: nil
      end

      def self.optional_text(document, field, message)
        text(document, field, message) if document.key?(field)
      end

      # Called under the store lock before mutation, including when a new
      # connection changed the authentication kind at that same location.
      def self.refuse_if_superseded(store, connection:)
        persisted = read(store)
        if persisted && persisted.connection != connection
          raise ConnectionSuperseded,
            "#{store.description} now holds a different connection; this one was superseded by a reconnect"
        end
        nil
      end
    end
  end
end
