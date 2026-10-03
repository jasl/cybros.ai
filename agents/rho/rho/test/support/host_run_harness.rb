require "test_helper"

module RhoTest
  module HostRunHarness
    Event = Data.define(:sequence, :cursor, :public_id, :type, :payload)
    Page = Data.define(:items, :next_after, :watermark)

    def event(sequence, type, payload)
      Event.new(sequence: sequence, cursor: "c#{sequence}", public_id: "e#{sequence}",
                type: type, payload: payload)
    end

    class Socket
      attr_reader :unsubscribed

      def initialize(events, ending: nil)
        @events = events
        @ending = ending
        @unsubscribed = 0
      end

      def each(&block)
        @events.each(&block)
        raise @ending if @ending
      end

      def unsubscribe = @unsubscribed += 1
    end

    class Realtime
      def rebind = true
      def close = nil
    end

    # Stands in for one host context — a loop's or a conversation's, the
    # same two methods. `asked` records the narrowing each subscription
    # opened with, because "which stream did it subscribe to" is a property
    # under test as much as what arrived on it.
    class Context
      attr_reader :asked, :asked_transcript, :asked_progress, :children_reads

      def initialize(pages, sockets: nil, transcript_sockets: nil, progress_sockets: nil, raise_once: nil, children: [])
        @pages = pages
        @sockets = sockets
        @transcript_sockets = transcript_sockets
        @progress_sockets = progress_sockets
        @raise_once = raise_once
        @asked = []
        @asked_transcript = []
        @asked_progress = []
        # THE CHILD LISTING: the summaries `children` answers,
        # scripted whole; every read is counted.
        @children = children
        @children_reads = 0
      end

      def children(after: nil, limit: nil)
        @children_reads += 1
        CybrosAgent::Api::Page.new(items: @children, next_after: nil)
      end

      # THE SECOND OPENER. The transcript feed is a tail with no
      # replay page behind it, so what a test scripts is a socket and
      # nothing else; a socket that raises its `ending` is how a loss is
      # written down.
      def transcript(realtime:)
        @asked_transcript << realtime
        sockets = @transcript_sockets
        -> { sockets&.shift || Socket.new([]) }
      end

      # THE THIRD OPENER: the host's progress feed, a tail of
      # frames with no page behind it, scripted like the transcript's.
      def progress(realtime:)
        @asked_progress << realtime
        sockets = @progress_sockets
        -> { sockets&.shift || Socket.new([]) }
      end

      def realtime_opener(_client, items: nil)
        @asked << items
        sockets = @sockets
        -> { sockets&.shift || Socket.new([]) }
      end

      def feed(realtime: nil, items: nil, **options)
        pages = @pages
        CybrosAgent::KernelFeed.new(
          replay: lambda { |_cursor|
            if @raise_once
              error = @raise_once
              @raise_once = nil
              raise error
            end
            pages.shift || Page.new(items: [], next_after: nil, watermark: 0)
          },
          subscribe: realtime && realtime_opener(realtime, items: items), **options
        )
      end
    end

    LOOP = Rho::Host::AgentLoop.new(public_id: "al-1")
    CONVERSATION = Rho::Host::Conversation.new(public_id: "c-1")

    def run_for(pages, host: LOOP, sockets: nil, transcript_sockets: nil, progress_sockets: nil,
                sleeper: ->(_seconds) { }, children: [], **options)
      @context = Context.new(pages, sockets: sockets, transcript_sockets: transcript_sockets,
        progress_sockets: progress_sockets, children: children)
      @realtime = (sockets || transcript_sockets || progress_sockets) && Realtime.new
      Rho::HostRun.new(
        host: host, context: @context,
        realtime: @realtime, sleeper: sleeper, **options
      )
    end

    # A REAL `TranscriptItem`, never a Struct: the class under test reads
    # `type`, `text`, `turn` and the four correlation keys by name, and a
    # Struct would let a renamed reader pass.
    def transcript_item(type, turn: nil, variant: nil, loop_id: nil, task_key: nil,
                        turn_row: nil, **payload)
      CybrosAgent::Api::TranscriptItem.new(
        type: type, turn_public_id: turn, variant_public_id: variant,
        agent_loop_public_id: loop_id, task_key: task_key, turn: turn_row,
        payload: payload.transform_keys(&:to_s)
      )
    end

    def delta_item(text, task_key: "r1", **rest)
      transcript_item("text_delta", task_key: task_key, text: text, **rest)
    end

    # The settled turn as the kernel publishes it: the WHOLE sealed body on
    # the active variant, which is what replace-on-settle takes.
    def settled_turn_item(content, turn: "t-1")
      variant = CybrosAgent::Api::ConversationVariant.new(
        public_id: "v-1", source: "model", status: "completed", model: nil,
        content_preview: content.to_s[0, 8], content: content, active: true
      )
      transcript_item("turn", turn: turn, turn_row: CybrosAgent::Api::ConversationTurn.new(
        public_id: turn, position: 1, kind: "direct_reply", role: "assistant",
        status: "completed", visibility: "visible", inherited: false,
        sender_conversation_public_id: nil, active_variant: variant, created_at: nil,
        answering_user_public_id: "0199-user"
      ))
    end

    def page(*events, watermark: nil)
      Page.new(items: events, next_after: events.last&.cursor,
               watermark: watermark || events.last&.sequence || 0)
    end

    def task_event(sequence, key, status, **rest)
      event(sequence, "task_status",
            { "task_key" => key, "status" => status }.merge(rest.transform_keys(&:to_s)))
    end

    # A STANDALONE LOOP's own item: the loop-locked write carries both the
    # loop's word and the turn shape.
    def loop_event(sequence, status, loop_status: status, **rest)
      event(sequence, "turn_status",
            { "status" => status, "loop_status" => loop_status,
              "agent_loop_public_id" => "al-1" }.merge(rest.transform_keys(&:to_s)))
    end

    # A CONVERSATION host's two writers: the loop-locked note, with
    # no `status`; and settle's item, with the turn's.
    def note_event(sequence, loop_status, **rest)
      event(sequence, "turn_status",
            { "loop_status" => loop_status, "agent_loop_public_id" => "al-1",
              "turn_public_id" => "t-1" }.merge(rest.transform_keys(&:to_s)))
    end

    def settle_event(sequence, status, **rest)
      event(sequence, "turn_status",
            { "status" => status, "turn_public_id" => "t-1", "variant_public_id" => "v-1",
              "agent_loop_public_id" => "al-1" }.merge(rest.transform_keys(&:to_s)))
    end

    # The gate is nudged only when the table shows a hold parked behind a
    # settled check with nothing else live (`check-1` is a tool row, `hold-1` the await); the verdict is the gate's, from the trace.
    def fake_gate(looks, loop_public_id: nil)
      gate = Object.new
      gate.define_singleton_method(:loop_public_id) { loop_public_id }
      gate.define_singleton_method(:worth_a_look?) { |tasks| tasks.any? { |t| t.task_key == "hold-1" && t.started? } }
      gate.define_singleton_method(:reconsider) { |context| looks << context }
      gate.define_singleton_method(:cancel!) { looks << :cancelled }
      gate.define_singleton_method(:to_h) { { "command" => "t" } }
      gate
    end
  end
end
