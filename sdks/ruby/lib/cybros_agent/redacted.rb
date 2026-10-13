module CybrosAgent
  # Data#to_s and pp do not consult a custom #inspect, so a redacting inspect
  # has to route the other two diagnostics through itself.
  module Redacted
    def to_s = inspect

    def pretty_print(printer) = printer.text(inspect)

    private

      def redacted(hidden: [], **fields)
        shown = fields.map { |name, value| "#{name}=#{value.inspect}" }
        concealed = hidden.map { |name| "#{name}=#{Redaction::REPLACEMENT}" }
        Redaction.call("#<#{self.class.name} #{(shown + concealed).join(" ")}>")
      end
  end
end
