require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationInputLoadingTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  %w[raw inline].each do |prompt_kind|
    test "materializing one #{prompt_kind} reply does not read the long prompts still waiting behind it" do
      conversation = create_conversation!
      prompt = implementation_review_prompt
      ids = 21.times.map do |index|
        fields = { kind: "direct_reply", text: "question #{index}",
          model: { model: DevModelLane::WINDOWLESS_TEXT_MODEL } }
        if prompt_kind == "raw"
          fields.merge!(context_mode: "raw", instructions: prompt)
        else
          fields[:inline] = [{ role: "developer", text: prompt }]
        end
        post conversation_inputs_path(conversation), headers: auth("#{prompt_kind}-#{index}"),
          as: :json, params: { input: fields }
        assert_response :accepted
        response.parsed_body.fetch("input").fetch("public_id")
      end

      result = nil
      reads = input_payload_reads do
        result = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
      end

      assert_predicate result, :accepted?, result.outcome.to_s
      assert_equal 20, conversation.conversation_inputs.count
      invocation = result.value.active_variant.model_invocation
      if prompt_kind == "raw"
        assert_equal prompt, invocation.request_options.fetch("instructions")
      else
        body = invocation.content_bodies.find_by!(role: "request")
        entry = body.content_body_entries.includes(:content_fragment).first
        assert_equal prompt, entry.content_fragment.payload.dig("parts", 0, "text")
      end

      waiting_reads = reads.select { |read| ids.drop(1).include?(read.fetch(:public_id)) }
      unused_bytes = waiting_reads.sum { |read| read.fetch(:bytes) }
      assert_equal 0, unused_bytes,
        "#{prompt_kind}: one selected reply read #{reads.length} input rows, " \
          "including #{waiting_reads.length} waiting rows / #{unused_bytes} unused prompt bytes"
    end
  end

  test "input listing batches ordered attachment parts as the pending queue grows" do
    conversation = create_conversation!
    picture = @account.content_uploads.create!(
      creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(PNG), filename: "diagram.png", content_type: "image/png", identify: false
      )
    )
    add_picture_input(conversation, picture, 0)
    list_inputs(conversation)
    small = attachment_queries { list_inputs(conversation) }

    19.times { |index| add_picture_input(conversation, picture, index + 1) }
    large = attachment_queries { list_inputs(conversation) }

    inputs = response.parsed_body.fetch("inputs")
    assert_equal 20, inputs.length
    assert_equal 20.times.map { |index| "picture #{index}" }, inputs.map { |input| input.fetch("text") }
    assert_equal [picture.public_id] * 20,
      inputs.map { |input| input.dig("attachments", 0, "public_id") }
    assert_operator large.length, :<=, small.length,
      "one to twenty pending attachment bodies: #{small.length} -> #{large.length} queries\n#{large.join("\n")}"
  end

  private

    def implementation_review_prompt
      paths = %w[
        app/services/agent_runs/tasks/compile.rb
        app/services/agent_runs/tasks/step.rb
        app/services/agent_runs/tasks/append.rb
        app/services/conversations/inputs/apply_next.rb
        app/services/conversations/inputs/reply_materialization.rb
      ]
      "Review the following implementation for task ordering, input ownership, and lifecycle correctness.\n\n" +
        paths.map { |path| "File: #{path}\n```ruby\n#{Rails.root.join(path).read}\n```" }.join("\n\n")
    end

    def input_payload_reads
      reads = []
      connection = ApplicationRecord.lease_connection
      select_all = connection.method(:select_all)
      connection.clear_query_cache
      connection.stub(:select_all, lambda { |*arguments, **options|
        result = select_all.call(*arguments, **options)
        if result.columns.include?("queue_position") && result.columns.include?("context_options")
          public_id = result.columns.index("public_id")
          payload_positions = %w[instructions context_options request_options].filter_map do |field|
            result.columns.index(field)
          end
          result.rows.each do |row|
            reads << { public_id: row.fetch(public_id),
              bytes: payload_positions.sum { |position| row.fetch(position).to_s.bytesize } }
          end
        end
        result
      }) { yield }
      reads
    end

    def add_picture_input(conversation, picture, index)
      post conversation_inputs_path(conversation), headers: auth("picture-#{index}"),
        as: :json, params: { input: { text: "picture #{index}", attachments: [picture.public_id] } }
      assert_response :accepted
    end

    def list_inputs(conversation)
      get conversation_inputs_path(conversation), headers: auth
      assert_response :success
    end

    def attachment_queries
      queries = []
      ApplicationRecord.connection_pool.clear_query_cache
      observer = lambda do |*, payload|
        sql = payload[:sql]
        unless payload[:cached]
          queries << sql if sql.match?(/FROM "(?:content_body_entries|content_fragments)"/)
        end
      end
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { yield }
      queries
    end
end
