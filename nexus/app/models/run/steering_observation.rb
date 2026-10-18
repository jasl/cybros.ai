class Run
  # Existing input and retained narration facts for one caller-authorized Run.
  # An absent waiting row says nothing about whether a correction was consumed.
  class SteeringObservation
    attr_reader :input, :task

    def initialize(run:, input_public_id:)
      @run = run
      host = run.host
      @input = host.inputs.find_by(public_id: input_public_id)
      if input
        raise ActiveRecord::RecordNotFound unless input.expected_steering_run_public_id == run.public_id
        return
      end

      envelope = host.events.find_by(idempotency_key: input_public_id)
      @accepted_event = envelope&.event_items&.find_by(item_type: "input_accepted")
      @terminal_event = host.event_items
        .where("item_type IN ('input_materialized', 'input_deleted')")
        .where("payload ->> 'input_public_id' = ?", input_public_id)
        .order(sequence: :desc).first

      check_target(@accepted_event&.payload&.fetch("expected_steering_run_public_id", nil))
      terminal_target = if @terminal_event&.item_type == "input_materialized"
        @terminal_event.payload["run_public_id"]
      else
        @terminal_event&.payload&.fetch("expected_steering_run_public_id", nil)
      end
      check_target(terminal_target)
      @task = run.tasks.find_by(node_key: @terminal_event.payload.fetch("task_key")) if consumed?
    end

    def accepted?
      input.present? || consumed? || canceled? ||
        @accepted_event&.payload&.fetch("expected_steering_run_public_id", nil) == @run.public_id
    end

    def waiting? = input&.steering? == true

    def consumed?
      @terminal_event&.item_type == "input_materialized" &&
        @terminal_event.payload["run_public_id"] == @run.public_id &&
        @terminal_event.payload["task_key"].present?
    end

    def canceled?
      @terminal_event&.item_type == "input_deleted" &&
        @terminal_event.payload["steer_canceled"] == true &&
        @terminal_event.payload["expected_steering_run_public_id"] == @run.public_id
    end

    private

      def check_target(public_id)
        raise ActiveRecord::RecordNotFound if public_id.present? && public_id != @run.public_id
      end
  end
end
