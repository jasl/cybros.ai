module ContentBodies
  # THE ONE MEASURE of a request's storage bytes: the canonical
  # size of each entry, summed — the number the seal judges
  # (`Replace#bound_refusal`), the composer's wall (`AgentLoops::InputComposition::MAX_COMPOSED_BYTES`) and the preview's `storage`
  # line all read. One formula, one bound (`snapshot_bound`), so a preview
  # that says "within" is a seal that will not refuse. The stored
  # `content_bodies.byte_size` is a different fact — the bytes
  # `effective_text` answers — and stays the writer's own.
  #
  # Both dimensions take the body's bound: every entry alone and the
  # aggregate; a compiled entry is always larger than the accepted entry
  # it came from, so one bound serves both.
  module Measure
    module_function

    BOUND = :snapshot_bound

    Measured = Data.define(:bytes, :bound, :refusal) do
      def within_bound? = refusal.nil?
    end

    # The entries as the seal writes them (`InputEntries.for`'s hashes).
    def call(entries)
      of_sizes(entries.map { |payload| Nexus::CanonicalJson.bytesize(payload) })
    end

    # The same rule over sizes a caller already has (the seal addresses
    # every entry for its digest and holds the byte count beside it).
    def of_sizes(sizes)
      bound = Nexus::SizeBounds.fetch(BOUND)
      bytes = sizes.sum
      within = sizes.all? { |size| Nexus::SizeBounds.bytes_within?(BOUND, size) } &&
        Nexus::SizeBounds.bytes_within?(BOUND, bytes)
      Measured.new(bytes: bytes, bound: bound, refusal: within ? nil : Nexus::SizeBounds::REJECTION)
    end
  end
end
