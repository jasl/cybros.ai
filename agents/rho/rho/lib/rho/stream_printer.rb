module Rho
  # THE TERMINAL'S HALF OF THE STREAM. Model text is
  # not lines: it arrives mid-word, and rho's other output IS lines that
  # the paid lanes parse anchored (`^loop:`, `^status:`, `^  check 1/3:`).
  # So this owns ONE fact — whether the cursor is mid-line — and every
  # structured line rho prints goes through it.
  #
  # It is a DECORATOR on the IO, not a second printer beside it: `Cli#out`
  # answers this object, so `cli.out.puts` from every extension verb emits
  # the pending newline first and no call site has to remember. That is
  # also why nothing was added to the pinned CLI surface.
  class StreamPrinter
    # A GUTTER, not two spaces. `rho watch`'s own table is indented too, and
    # a model whose reply contains a line beginning "ask …" or "completed …"
    # would otherwise print something an anchored lane reads as a table row
    # — which is not hypothetical: the mock echoes its whole prompt, and
    # `ask_inbox`'s `refute_match(/^  ask\s/)` caught it the first time this
    # ran. Nothing rho prints at column zero or in its table can start with
    # this, so the two are separable by eye and by regexp.
    INDENT = "  │ ".freeze
    RESET_LINE = "  (restarted — the text above was discarded)".freeze
    DIM = "\e[2m".freeze
    UNDIM = "\e[0m".freeze

    # The same ceiling the follower holds: what this keeps is only what it
    # needs to tell a continuation from a restart.
    BOUND = 64 * 1024

    def initialize(io)
      @io = io
      @mid_line = false
      @channel = nil
      @printed = false
      # What a POLLING reader has already shown, and how many bytes of the
      # daemon's own accumulation that accounts for. The two are different
      # numbers once the answer passes the daemon's bound: what it holds is
      # then a TAIL, and only the count can say how much of it is new.
      @stream = { text: accumulator, reasoning: accumulator }
    end

    # THE ONE RULE. A structured line never lands on the end of a delta.
    def puts(line = "")
      break_line
      @channel = nil
      @io.puts(line)
    end

    def print(*args)
      @io.print(*args)
      note(args.join)
    end

    def write(*args)
      written = @io.write(*args)
      note(args.join)
      written
    end

    def flush = @io.flush

    # Whether a delta left the cursor mid-line: what a verb that prints
    # text alone asks before it ends.
    def mid_line? = @mid_line

    def tty? = @io.respond_to?(:tty?) && @io.tty?

    # One assistant delta into the indented block. Flushed per delta on
    # purpose: a stream nobody sees until a pipe buffer fills is not a
    # stream.
    def text(delta) = emit(@stream.fetch(:text).accumulate(delta.to_s), channel: :text)

    # The second channel, dimmed only for a person: e2e reads this output
    # through a pipe, and an escape code there is a byte every anchored
    # lane would have to know about.
    def reasoning(delta) = emit(@stream.fetch(:reasoning).accumulate(delta.to_s), channel: :reasoning, dim: true)

    # ONE MARKER LINE, and only when there is something to disown: a
    # `stream_reset` that follows another says nothing new.
    def reset
      @stream.each_value(&:reset)
      mark_reset
    end

    # THE POLLING ENTRY POINT (`rho watch` reads a snapshot; nobody hands
    # it deltas), and the join-time seed for a follower seeing the
    # daemon's accumulated partial in its first frame. `length` is the
    # snapshot's `text_length` — every byte that went in, which is more
    # than `text` holds once the answer passes the daemon's bound. Without
    # it each poll past that bound reads as a replacement and reprints the
    # whole window once a second.
    def partial(text, length: nil, channel: :text)
      return if text.nil?

      stream = @stream.fetch(channel)
      shown = stream.replace_snapshot(text.to_s, length: length)
      if stream.replaced?
        @stream.each { |name, held| held.reset unless name == channel }
        mark_reset
      end
      emit(shown, channel: channel, dim: channel == :reasoning)
    end

    private

      def mark_reset
        return unless @printed

        @printed = false
        break_line
        @channel = nil
        @io.puts(RESET_LINE)
      end

      def accumulator = CybrosAgent::Api::TranscriptAccumulator.new(bound: BOUND)

      def emit(delta, channel:, dim: false)
        delta = delta.to_s.dup.force_encoding(Encoding::UTF_8)
        return if delta.empty?

        break_line if @channel != channel && @mid_line
        @channel = channel
        @printed = true
        @io.write(block(delta, dim: dim && tty?))
        @io.flush
      end

      # The block's indent leads every line of it, so a delta carrying a
      # newline stays inside the block rather than escaping into the
      # anchored lines around it.
      def block(delta, dim:)
        rendered = +""
        delta.each_line do |line|
          rendered << INDENT unless @mid_line
          body = line.chomp("\n")
          rendered << (dim ? "#{DIM}#{body}#{UNDIM}" : body)
          rendered << "\n" if line.end_with?("\n")
          @mid_line = !line.end_with?("\n")
        end
        rendered
      end

      def break_line
        return unless @mid_line

        @io.write("\n")
        @mid_line = false
      end

      def note(written)
        return if written.empty?

        @mid_line = !written.end_with?("\n")
      end
  end
end
