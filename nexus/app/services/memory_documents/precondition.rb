module MemoryDocuments
  # A scoped path selects a document; the observed row and version only
  # constrain that selection. Identity prevents delete/recreate from matching
  # an old version zero. Explicit absence is useful only for creation.
  class Precondition < Data.define(:public_id, :lock_version)
    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    VERSION_RANGE = 0..(2**31 - 1)

    def self.parse(fields, allow_absent:)
      public_id = fields.fetch("expected_public_id")
      version = fields.fetch("expected_lock_version")
      if public_id.nil? && version.nil? && allow_absent
        new(public_id: nil, lock_version: nil)
      else
        public_id = public_id.to_s.downcase
        unless public_id.bytesize == 36 && public_id.match?(UUID_FORMAT)
          raise ArgumentError, "expected_public_id"
        end
        begin
          version = Integer(version.to_s, 10)
        rescue ArgumentError
          raise ArgumentError, "expected_lock_version"
        end
        raise ArgumentError, "expected_lock_version" unless VERSION_RANGE.cover?(version)

        new(public_id: public_id, lock_version: version)
      end
    end

    def matches?(document)
      if public_id.nil?
        document.nil?
      else
        document && document.public_id == public_id && document.lock_version == lock_version
      end
    end
  end
end
