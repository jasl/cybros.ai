require "cybros_agent"
require "rho/runner"

module Rho
  module Mcp
    # THE KERNEL'S BOUND, MET PER SERVER. An
    # address's announcement is ONE PUT the kernel judges whole under
    # `envelope_bound` (65,536 canonical bytes, `CybrosAgent::SizeBounds`):
    # one server's verbatim descriptions past it would void the host's
    # own tools and every other server's — the announcement refused, the
    # runner alive and addressable by nothing. So each server's curated
    # tools are measured AS THE KERNEL MEASURES THEM — the announcement
    # entries the registry renders (`Registry::Entry#announcement`), in
    # canonical bytes — cumulatively in settings order, on top of what
    # the host announced on that address before this extension
    # (`api.announced`: the built-ins, in load order). The server that
    # would cross the bound is refused as a ROW-LEVEL FAULT naming its
    # bytes, the total and the bound: nothing of it is announced (a
    # partial announcement would be a silent one), its child is closed,
    # and the rows after it are judged on the ledger without it. The WARN
    # line past ADR-0040's reference bytes stays the operator's signal
    # below the wall; this is the wall.
    class Budget
      BOUND = CybrosAgent::SizeBounds::ENVELOPE_BOUND

      # The ledger as it stands: each address's entries, the host's and
      # every row judged onto it — what the boot table leaves behind for a
      # conversation set to be judged on top of (`Rho::Mcp.ledger`).
      attr_reader :ledger

      # `announced` is the handle's: `{runner: [...], agent: [...]}` — or
      # a ledger this class answered.
      def initialize(announced)
        @ledger = Rho::Runner::Extensions::Api::SERVES.to_h { |serves| [serves, Array(announced&.dig(serves))] }
      end

      # The kernel-shaped entries of one curation — what `judge` adds to
      # the ledger, and what a conversation set records for the sets
      # opened after it (`Conversations::Set#kernel_entries`).
      def self.entries_for(curated)
        curated.announced.map do |tool|
          Rho::Runner::Extensions::Tool.announcement(tool.klass, name: tool.public_name)
        end
      end

      # The curation as judged: the same `Curated` when it already carries
      # a fault or its tools fit (they are then on the address's ledger),
      # else the row's `down` naming the bytes.
      def judge(row, curated)
        return curated if curated.fault

        entries = self.class.entries_for(curated)
        before = @ledger.fetch(row.serves)
        total = CybrosAgent::SizeBounds.canonical_bytesize(before + entries)
        if total > BOUND
          return Curation.down(row, "its #{entries.length} tools (#{number(bytes(entries))} bytes as the kernel " \
                                    "measures an announcement) would put the #{row.serves} address's announcement " \
                                    "at #{number(total)} bytes, past the kernel's envelope_bound (#{number(BOUND)} " \
                                    "bytes); #{number(bytes(before))} bytes were announced there before it")
        end

        @ledger = @ledger.merge(row.serves => before + entries)
        curated
      end

      private

        def bytes(entries) = CybrosAgent::SizeBounds.canonical_bytesize(entries)

        def number(value) = Mapping.number(value)
    end
  end
end
