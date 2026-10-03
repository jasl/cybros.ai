module Rho
  module Dev
    # THE PUSHED STREAM RENDERED: `rho watch` prints what moved; this
    # prints what happened — the same stream a console reads, so it is
    # debuggable from a terminal first. Ends with the loop or the person.
    module Follow
      def self.register(api)
        api.register_command("follow", usage: "follow LOOP_ID",
          description: "Print this loop's events as they land, the reply as it is written (Ctrl-C to stop)",
          options: {
            timeout: { type: :numeric, desc: "Give up after this many seconds" },
          }.merge(Rho::Dev::STREAM_OPTIONS),
          &method(:follow))
      end

      class << self
        def follow(cli, (public_id), options)
          cli = Rho::Dev.terminal(cli)
          seen = {}
          reasoning = options[:reasoning] == true
          stream = options.fetch(:stream, true) != false
          cli.core.loop_events(public_id, deadline: options[:timeout]) do |type, payload|
            case type
            when "snapshot"
              cli.report_tasks(payload, seen)
              cli.report_todo(payload, seen)
              # THE JOIN-TIME PARTIAL: the route sends the follower's own
              # snapshot first, and it already carries what was
              # accumulated before this reader arrived — so a person
              # joining a running reply sees it, not a blank block. BOTH
              # channels: the reasoning a reply opened
              # with rides the same snapshot, and a reader joining on
              # the events terminal — the turn settled, its text not yet
              # — would otherwise print the settle's text remainder under
              # no reasoning at all, since the kernel's settled turn
              # carries a text body and no reasoning body.
              cli.out.partial(payload["reasoning"], channel: :reasoning) if reasoning
              cli.out.partial(payload["text"], length: payload["text_length"]) if stream
            when "text_delta" then cli.out.text(payload["text"].to_s) if stream
            when "reasoning_delta" then cli.out.reasoning(payload["text"].to_s) if reasoning
            when "stream_reset" then cli.out.reset if stream
            when "task_status", "round_result"
              cli.report_tasks({ "tasks" => [payload] }, seen)
              cli.report_todo({ "tasks" => [payload] }, seen)
            # A kernel frame naming a call's tool is what the checklist
            # keys on; the frames print nowhere here.
            when "progress" then cli.report_todo({ "frames" => [payload] }, seen)
            when "input_accepted"
              # The wrapped origins, and a SCHEDULED row
              # whatever its origin: `scheduled: <input> for <time>`.
              if payload["deliver_at"] || Rho::HostRun::WRAPPED_ORIGINS.include?(payload["origin"])
                cli.report_tasks({ "mailed" => [payload] }, seen)
              end
            when "attention_required" then cli.report_attention("attention" => payload)
            when "turn_status"
              # `status` is the TURN's and optional: absent, the
              # item is a loop-state note and the turn did not move.
              cli.out.puts "status:    #{payload["status"]}" if payload["status"]
            when "closed"
              cli.out.puts "(stream ended: #{payload["reason"]})"
            else
              # An item type this CLI predates advances nothing and means
              # nothing here — the same tolerance the follower keeps, so a
              # new kernel vocabulary entry does not stop a person watching.
              nil
            end
          end
          public_id
        end
      end
    end
  end
end
