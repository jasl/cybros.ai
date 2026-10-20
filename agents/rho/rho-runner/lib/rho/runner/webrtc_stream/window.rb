module Rho
  class Runner
    class WebrtcStream
      # A disposable capture window, independent of peer lifetimes. Missing
      # ranges need no stored markers: offsets expose every omission.
      class Window
        Chunk = Data.define(:offset, :bytes, :at)
        private_constant :Chunk

        def initialize(max_bytes:, max_age:, clock:)
          raise ArgumentError, "invalid output window bounds" unless max_bytes.positive? && max_age.positive? && max_age.finite?

          @max_bytes = max_bytes
          @max_age = max_age
          @clock = clock
          @chunks = []
          @retained_bytes = 0
          @end_offset = 0
        end

        attr_reader :end_offset, :retained_bytes

        def append(bytes, retain:)
          raise ArgumentError, "output block exceeds 16 KiB" if bytes.bytesize > WebrtcTransport::MAX_BYTES
          raise Error, "realtime output offset overflow" if @end_offset + bytes.bytesize > MAX_OFFSET

          now = @clock.call
          if retain
            position = 0
            while position < bytes.bytesize
              data = bytes.byteslice(position, BLOCK_BYTES).b
              @chunks << Chunk.new(offset: @end_offset + position, bytes: data, at: now)
              @retained_bytes += data.bytesize
              position += data.bytesize
            end
          end
          @end_offset += bytes.bytesize
          prune(now)
          nil
        end

        def next_frame(offset)
          raise Error, "resume offset is beyond captured output" unless (0..@end_offset).cover?(offset)

          prune(@clock.call)
          chunk = @chunks.find { |entry| entry.offset + entry.bytes.bytesize > offset }
          if chunk && offset >= chunk.offset
            Output.new(offset: offset, bytes: chunk.bytes.byteslice(offset - chunk.offset, BLOCK_BYTES))
          elsif offset < @end_offset
            # After an overrun, chasing the oldest block can yield gaps forever
            # as the producer evicts it before the next request. Catch up to live
            # output and explicitly account for the skipped backlog.
            Gap.new(from: offset, to: chunk ? @chunks.last.offset : @end_offset)
          end
        end

        def expire
          prune(@clock.call)
          nil
        end

        def clear
          @chunks.clear
          @retained_bytes = 0
          nil
        end

        private

          def prune(now)
            while @chunks.any? && (@retained_bytes > @max_bytes || @chunks.length > 256 || now - @chunks.first.at >= @max_age)
              @retained_bytes -= @chunks.shift.bytes.bytesize
            end
          end
      end
    end
  end
end
