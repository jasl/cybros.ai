require "application_system_test_case"
require "net/http"

module ConversationAttachmentsJourney
  extend ActiveSupport::Concern
  include InvocationHarness

  included do
    include ActiveJob::TestHelper

    setup do
      @previous_forgery_protection = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      @account = accounts(:cybros)
      @human = users(:member)
      @workspace = workspaces(:shared)
      @agent = connect_agent_session(steward: @human, agent_identifier: "attachments.browser",
        display_name: "Attachment Agent").access_token.user
      @agent.update!(default_model: "dev/mock-text")
      DevModelLane.ensure_enabled!(@account)
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
        answering_user: @agent, title: "Work with files")
      sign_in_directly(@human)
    end

    teardown do
      ActionController::Base.allow_forgery_protection = @previous_forgery_protection
    end

    test "a Task capture offers its actual file for download through the current browser session" do
      run = Run.create!(workspace: @workspace, creating_user: users(:owner), status: "completed", approval_mode: "bypass")
      bytes = PngFixture.bytes(width: 40, height: 30)
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: "captured-diagram.png",
        content_type: "image/png", identify: false)
      upload = @account.content_uploads.create!(creating_executor: executors(:address), file: blob)
      task = run.tasks.create!(node_key: "captured-file", type: Tasks::ToolTask.sti_name,
        tool_name: "read_file", tool_input: {}, authored_by: "author")
      task.update_columns(status: "completed", started_at: Time.current, completed_at: Time.current)
      result = ContentBodies::Replace.call(owner: task, role: "output", entries: [
        { "text" => "The diagram is ready." },
        { "resource_link" => { "uri" => "nexus://uploads/#{upload.public_id}", "name" => "Tool supplied label" } },
      ], uploads: [upload], seal: true)
      assert_predicate result, :accepted?

      visit run_task_path(run, task.node_key)
      assert_current_path run_task_path(run, task.node_key)
      assert_text "The diagram is ready."
      within("ul[aria-label='Attachments']") do
        assert_text "image/png"
        assert_link "Preview", href: upload_preview_path(upload_public_id: upload.public_id)
        response = download_with_browser_session(find_link("captured-diagram.png")[:href])
        assert_equal "200", response.code
        assert_equal "image/png", response.content_type
        assert_equal bytes.b, response.body.b
      end
      assert_page_fits_viewport
      page.save_screenshot(Rails.root.join("tmp/screenshots/attachments-#{viewport_name}-task.png"))
    end
  end

  private

    def download_with_browser_session(href)
      uri = URI.join(page.current_url, href)
      request = Net::HTTP::Get.new(uri)
      request["Cookie"] = page.driver.browser.manage.all_cookies.map { |cookie| "#{cookie.fetch(:name)}=#{cookie.fetch(:value)}" }.join("; ")
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    end

    def assert_page_fits_viewport
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end

class ConversationAttachmentsJourneyTest < ApplicationSystemTestCase
  include ConversationAttachmentsJourney

  private

    def viewport_name = "desktop"
end

class MobileConversationAttachmentsJourneyTest < MobileSystemTestCase
  include ConversationAttachmentsJourney

  private

    def viewport_name = "mobile"
end
