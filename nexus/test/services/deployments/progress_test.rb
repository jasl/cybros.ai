require "test_helper"
require_relative "../../test_helpers/deployment_test_helper"

class Deployments::ProgressTest < ActiveSupport::TestCase
  include DeploymentTestHelper

  setup do
    @admin = users(:member)
    assert_equal :role_changed, @admin.change_role(to: :admin)
    @token = create_access_token_fixture(user: @admin, name: "Progress operator", plane: :platform)
    @client = fake_deployment_client
  end

  test "demotion while the next local log read is in flight prevents its delivery" do
    verify_cut_during_read { assert_equal :role_changed, @admin.change_role(to: :member) }
  end

  test "credential revocation while the next local log read is in flight prevents its delivery" do
    verify_cut_during_read { @token.token.revoke }
  end

  test "a revoked browser session cannot receive an already-read initial log window" do
    session = create_browser_session(@admin.identity)
    initial = @client.log(operation_id: OPERATION_ID)
    session.destroy!
    progress = Deployments::Progress.new(client: @client, session: session, access_token: nil)
    events = []

    progress.stream(operation_id: OPERATION_ID, cursor: nil, initial: initial) do |event, data|
      events << [event, data]
    end

    assert_equal [:error], events.map(&:first)
    assert_equal :administrator_required, events.sole.last.code
    assert_equal 1, @client.calls.length
  end

  test "an empty terminal log window stops observation with a missing or stale persisted tail" do
    [nil, "earlier"].each do |persisted_tail|
      receipt = @client.upgrade_receipt.with(status: "interrupted", log_cursor: persisted_tail)
      log = Nexus::Deployment::Log.new(entries: [], next_cursor: "tail", operation: receipt)
      initial = Nexus::Deployment::Response.new(status: 200, data: log, error: nil)
      progress = Deployments::Progress.new(client: @client, session: nil, access_token: @token.token)
      events = []

      @client.stub(:log, ->(**) { flunk "A terminal empty window must not request another log window" }) do
        progress.stub(:sleep, nil) do
          progress.stream(operation_id: OPERATION_ID, cursor: nil, initial: initial) do |event, data|
            events << [event, data]
          end
        end
      end

      assert_equal [[:progress, log]], events
    end
  end

  private

    def verify_cut_during_read
      initial = @client.log(operation_id: OPERATION_ID)
      progress = Deployments::Progress.new(client: @client, session: nil, access_token: @token.token)
      events = []
      read = lambda do |**|
        yield
        initial
      end

      @client.stub(:log, read) do
        progress.stub(:sleep, nil) do
          progress.stream(operation_id: OPERATION_ID, cursor: nil, initial: initial) do |event, data|
            events << [event, data]
          end
        end
      end

      assert_equal [:progress, :error], events.map(&:first)
      assert_equal :administrator_required, events.last.last.code
    end
end
