module AgentRunAPITestHelper
  extend ActiveSupport::Concern

  MODEL = { model: "dev/mock-text" }.freeze

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @workspace = workspaces(:shared)
      @token = create_access_token_fixture(user: @human, name: "Member")
    end
  end

  private

    def created_loop(steps)
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: { run: { approval_mode: "bypass", steps: steps } }
      assert_response :created
      AgentRun.find_by!(public_id: response.parsed_body.dig("run", "public_id"))
    end

    def create_loop!
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: { approval_mode: "bypass", steps: [{ model: { key: "seed", model: MODEL, prompt: "s" } }] },
      }
      assert_response :created
      response.parsed_body.dig("run", "public_id")
    end

    def create_await_loop!
      post loops_path, headers: auth(SecureRandom.uuid), as: :json, params: {
        run: { approval_mode: "bypass", steps: [{ ask: { key: "gate", prompt: "?" } }] },
      }
      assert_response :created
      response.parsed_body.dig("run", "public_id")
    end

    def loop_record(public_id) = AgentRun.find_by!(public_id: public_id)

    def task_status_payloads(loop_id, key)
      loop_record(loop_id).conversation_event_items.where(item_type: "task_status").order(:sequence)
        .map(&:payload).select { |payload| payload["task_key"] == key }
    end

    def png_upload
      png = Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )
      @account.content_uploads.create!(
        creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: "step.png",
          content_type: "image/png")
      )
    end

    def post_input(loop_id, text, delivery_mode:)
      post "#{loops_path}/#{loop_id}/inputs", headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { text: text, delivery_mode: delivery_mode } }
      assert_response :accepted
      response.parsed_body.fetch("input")
    end

    def loops_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/runs"
    end

    def auth(key = nil)
      headers = { "Authorization" => "Bearer #{@token.secret}" }
      headers["Idempotency-Key"] = key if key
      headers
    end
end
