require "json"

module CybrosAgent
  # THE PACK'S SIZE BOUNDS A CALLER MEASURES AGAINST BEFORE THE WIRE
  # (contracts/nexus/v1/size_bounds.json), with the kernel's own measure:
  # a stored JSON payload is judged on its CANONICAL bytes — keys
  # codepoint-sorted, no insignificant whitespace, raw UTF-8, a zero float
  # spelled `0.0` (`content_addressing.json`, `encoding: canonical_json`)
  # — never on the bytes a caller happened to send. `ENVELOPE_BOUND` is
  # the bound on an executor's announcement (`served_tools`,
  # `served_documents`), which the kernel refuses WHOLE above it; an
  # announcer composing several sources into one PUT measures each here
  # first (rho-mcp's per-server budget). Pinned against the pack's value
  # and its canonical vectors by the gem's own test.
  module SizeBounds
    ENVELOPE_BOUND = 65_536

    module_function

    def canonical_bytesize(value) = JSON.generate(canonical(value)).bytesize

    def canonical(value)
      case value
      when Hash then value.sort_by { |key, _item| key.to_s }.to_h { |key, item| [key.to_s, canonical(item)] }
      when Array then value.map { |item| canonical(item) }
      when Float then value.zero? ? 0.0 : value
      else value
      end
    end
  end
end
