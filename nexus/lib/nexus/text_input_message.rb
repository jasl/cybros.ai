module Nexus
  # One message and its ordered closed part stream: text and each attachment
  # occurrence keep their relative positions, so a compiler never infers
  # membership from the Body's binding order.
  #
  # `phase` is a wire's own label on an assistant message it produced (the
  # Responses grammar's commentary | final_answer), carried with the
  # `native_origin` that licenses it: the compiler resends it only to the
  # wire and lane that wrote it. Both are absent on every other message, so
  # its bytes are the ones it always had.
  TextInputMessage = Data.define(:role, :parts, :phase, :native_origin) do
    def self.from_h(hash)
      new(
        role: hash.fetch("role"),
        parts: hash.fetch("parts").map { |part| InputParts.from_h(part) },
        phase: hash["phase"],
        native_origin: hash["native_origin"]
      )
    end

    def initialize(phase: nil, native_origin: nil, **) = super

    # The distinct Uploads this message PLACES, in first-occurrence order.
    # The same Upload may occur at several positions and is named once here:
    # this answers "which", never "how many times".
    def upload_public_ids
      parts.filter_map do |part|
        part.upload_public_id if part.type == InputParts::UPLOAD
      end.uniq
    end

    def to_h
      {
        "role" => role,
        "parts" => parts.map(&:to_h),
        "phase" => phase,
        "native_origin" => native_origin,
      }.compact
    end
  end
end
