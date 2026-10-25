require "base64"
require "json"

module Rho
  module Env
    class WebrtcStream
      BLOCK_BYTES = 8 * 1024
      MAX_OFFSET = 2**53 - 1
      Input = Data.define(:id, :bytes)
      Receipt = Data.define(:id, :sequence, :status, :bytes)
      Resume = Data.define(:offset)
      Resize = Data.define(:cols, :rows)
      Output = Data.define(:offset, :bytes)
      Gap = Data.define(:from, :to) do
        def message = "Output gap: #{to - from} bytes are unavailable."
      end

      module Protocol
        def self.encode(frame)
          value = case frame
          in Input(id:, bytes:)
            { type: "input", id: id, data: Base64.strict_encode64(bytes) }
          in Receipt(id:, sequence:, status:, bytes:)
            { type: "receipt", id: id, sequence: sequence, status: status, bytes: bytes }
          in Resize(cols:, rows:)
            { type: "resize", cols: cols, rows: rows }
          in Resume(offset:)
            { type: "resume", offset: offset }
          in Output(offset:, bytes:)
            { type: "output", offset: offset, data: Base64.strict_encode64(bytes) }
          in Gap(from:, to:)
            { type: "gap", from: from, to: to }
          else
            raise ArgumentError, "unknown realtime stream frame"
          end
          JSON.generate(value)
        end

        def self.decode(bytes)
          raise Error, "realtime stream frame too large" if bytes.bytesize > WebrtcTransport::MAX_BYTES

          value = JSON.parse(bytes).to_h
          case value.fetch("type")
          when "input"
            Input.new(id: positive(value.fetch("id")), bytes: block(value))
          when "receipt"
            status = value.fetch("status")
            count = offset(value.fetch("bytes"))
            raise Error, "invalid input receipt" unless %w[received written].include?(status) && count <= BLOCK_BYTES && (status != "received" || count.positive?)

            Receipt.new(id: positive(value.fetch("id")), sequence: positive(value.fetch("sequence")), status: status, bytes: count)
          when "resize"
            cols = offset(value.fetch("cols"))
            rows = offset(value.fetch("rows"))
            raise Error, "invalid terminal dimensions" unless (2..500).cover?(cols) && (2..200).cover?(rows)

            Resize.new(cols: cols, rows: rows)
          when "resume"
            Resume.new(offset: offset(value.fetch("offset")))
          when "output"
            start = offset(value.fetch("offset"))
            data = block(value)
            raise Error, "realtime output offset overflow" if start + data.bytesize > MAX_OFFSET

            Output.new(offset: start, bytes: data)
          when "gap"
            first = offset(value.fetch("from"))
            last = offset(value.fetch("to"))
            raise Error, "invalid realtime output gap" unless last > first

            Gap.new(from: first, to: last)
          else
            raise Error, "unknown realtime stream frame"
          end
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError, NoMethodError
          raise Error, "invalid realtime stream frame", cause: nil
        end

        def self.offset(value)
          number = Integer(value.to_s, 10)
          raise Error, "invalid realtime output offset" unless (0..MAX_OFFSET).cover?(number)

          number
        end

        def self.positive(value)
          number = offset(value)
          raise Error, "invalid input identifier" unless number.positive?

          number
        end

        def self.block(value)
          data = Base64.strict_decode64(value.fetch("data").to_s)
          raise Error, "invalid realtime stream block" unless (1..BLOCK_BYTES).cover?(data.bytesize)

          data
        end
        private_class_method :offset, :positive, :block
      end

      # Retain this receiver across peer replacements. Returned events are
      # consumed in order before its cursor is used for the next resume.
      class Receiver
        def initialize
          @offset = 0
          @input_id = 0
        end

        attr_reader :offset

        def resume = Protocol.encode(Resume.new(offset: @offset))

        def input(bytes)
          raise ArgumentError, "input block must contain 1..8 KiB" unless (1..BLOCK_BYTES).cover?(bytes.bytesize)

          @input_id += 1
          Protocol.encode(Input.new(id: @input_id, bytes: bytes))
        end

        def receive(bytes)
          case Protocol.decode(bytes)
          in Receipt => receipt
            [receipt]
          in Output(offset:, bytes: data)
            raise Error, "output is missing a gap frame" if offset > @offset

            finish = offset + data.bytesize
            if finish > @offset
              event = Output.new(offset: @offset, bytes: data.byteslice(@offset - offset, finish - @offset))
              @offset = finish
              [event]
            else
              []
            end
          in Gap(from:, to:)
            raise Error, "output gap is out of order" if from > @offset

            if to > @offset
              event = Gap.new(from: @offset, to: to)
              @offset = to
              [event]
            else
              []
            end
          else
            raise Error, "unexpected realtime output frame"
          end
        end
      end
    end
  end
end
