require "rho/env/webrtc_connection"
require "rho/env/webrtc_stream/protocol"
require "rho/env/webrtc_stream/window"

module Rho
  module Env
    # The existing handler owns this wrapper, its connection and its PTY.
    # Only output is recoverable; inputs are never queued for replay.
    class WebrtcStream
      def initialize(connection:, context:, resize: nil, window_bytes: 256 * 1024)
        @connection = connection
        @context = context
        @resize = resize
        @window = Window.new(max_bytes: window_bytes)
        @generation = nil
        @cursor = nil
        @resumed = false
        @closed = false
        @input_id = 0
        @input_sequence = 0
        @input_receipt = nil
      end

      def write_output(bytes)
        @context.raise_if_cancelled!
        raise Error, "realtime stream closed" if @closed

        # Even omitted bytes advance the position so a later viewer sees a
        # truthful gap, never the content captured without current permission.
        @window.append(bytes, retain: @context.realtime.allowed?)
      end

      def poll
        @context.raise_if_cancelled!
        raise Error, "realtime stream closed" if @closed

        packet = @connection.poll
        if @generation != @connection.connection_id || !packet.ready
          @input_id = 0 if @generation != @connection.connection_id
          @generation = @connection.connection_id
          @cursor = nil
          @resumed = false
          @input_receipt = nil
        end
        @window.clear if @context.realtime.closed?
        inputs = []
        packet.data.each do |bytes|
          case Protocol.decode(bytes)
          in Resume(offset:)
            raise Error, "resume offset is beyond captured output" if offset > @window.end_offset

            @cursor = offset
            @resumed = true
          in Resize(cols:, rows:)
            raise Error, "terminal resize arrived before resume" unless @resumed

            @resize&.call(cols, rows) if packet.ready && @context.realtime.allowed?
          in Input(id:, bytes: data)
            raise Error, "realtime input arrived before resume" unless @resumed

            next unless packet.ready && @context.realtime.allowed?
            raise Error, "input is already pending or out of order" if @input_receipt || id <= @input_id
            raise Error, "input sequence overflow" if @input_sequence >= MAX_OFFSET

            @input_id = id
            @input_sequence += 1
            @input_receipt = Receipt.new(id: id, sequence: @input_sequence, status: "received", bytes: data.bytesize)
            @connection.send_bytes(Protocol.encode(@input_receipt))
            inputs << data
          else
            raise Error, "unexpected realtime input frame"
          end
        end
        if packet.ready && @cursor && @context.realtime.allowed?
          frame = @window.next_frame(@cursor)
          if frame && @connection.send_bytes(Protocol.encode(frame))
            # One frame per cursor request bounds the remote helper queue even
            # when a resumed backlog is much larger than its receive buffer.
            @cursor = nil
          end
        end
        packet.with(data: inputs, ready: packet.ready && @resumed)
      end

      def acknowledge_input(bytes)
        @context.raise_if_cancelled!
        raise Error, "no pending input" unless @input_receipt
        raise Error, "invalid PTY write count" unless (0..@input_receipt.bytes).cover?(bytes)

        receipt = @input_receipt.with(status: "written", bytes: bytes)
        @input_receipt = nil
        if !@closed && @generation == @connection.connection_id && @context.realtime.allowed?
          @connection.send_bytes(Protocol.encode(receipt))
        end
        nil
      end

      def close
        @closed = true
        @window.clear
        @connection.close
      end
    end
  end
end
