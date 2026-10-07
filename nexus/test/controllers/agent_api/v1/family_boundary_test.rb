require "test_helper"
require_relative "../../../test_helpers/rate_limit_test_helper"

# The agent family's authentication boundary: bearer-only, never a cookie, and one bearer resolves
# to exactly one plane. A credential presented to the other plane's endpoint is fenced with 401
# rather than accepted with a degraded principal.
class AgentAPI::V1::FamilyBoundaryTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  NAT_ADDRESS = "198.51.100.24".freeze

  setup do
    @member = users(:agent)
    @executor = task_executors(:address)
    @transport = create_bound_credential(executor: @executor, name: "Transport")
    @credential = create_access_token_fixture(user: users(:member), name: "Member")
  end

  test "the member plane answers a member credential and refuses a transport one" do
    get agent_api_v1_profile_path, headers: bearer(@credential.secret)
    assert_response :success
    assert_nil response.headers["WWW-Authenticate"]

    get agent_api_v1_profile_path, headers: bearer(@transport.secret)
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_equal 'Bearer realm="Nexus"', response.headers["WWW-Authenticate"]
  end

  # Discovery is the MEMBER plane's: a transport credential never reads which executors a principal
  # may address.
  test "discovery answers a member credential and refuses a transport one" do
    get "/agent_api/v1/executors", headers: bearer(@credential.secret)
    assert_response :success
    get "/agent_api/v1/executors", headers: bearer(@transport.secret)
    assert_response :unauthorized

    get "/agent_api/v1/executors/#{@executor.public_id}", headers: bearer(@credential.secret)
    assert_response :not_found, "authenticated: an agent address is nobody's to address"
    get "/agent_api/v1/executors/#{@executor.public_id}", headers: bearer(@transport.secret)
    assert_response :unauthorized
  end

  test "the executor plane answers a transport credential and refuses a member one" do
    get agent_api_v1_executor_path, headers: bearer(@transport.secret)
    assert_response :success

    get agent_api_v1_executor_path, headers: bearer(@credential.secret)
    assert_response :unauthorized
    assert_equal 'Bearer realm="Nexus"', response.headers["WWW-Authenticate"]

    put agent_api_v1_executor_announcement_path, headers: bearer(@transport.secret),
      as: :json, params: { tools: [] }
    assert_response :success

    put agent_api_v1_executor_announcement_path, headers: bearer(@credential.secret),
      as: :json, params: { tools: [] }
    assert_response :unauthorized
  end

  # The inbox transport is the executor plane's alone: a member bearer never reaches the inbox, the
  # claim or the commit.
  test "the inbox doors answer a transport credential and refuse a member one" do
    get agent_api_v1_executor_inbox_path, headers: bearer(@transport.secret)
    assert_response :success
    get agent_api_v1_executor_inbox_path, headers: bearer(@credential.secret)
    assert_response :unauthorized

    loop_id = "01900000-0000-7000-8000-000000000099"
    claim = agent_api_v1_executor_inbox_claim_path(run_public_id: loop_id, task_key: "t")
    post claim, headers: bearer(@transport.secret)
    assert_response :not_found, "authenticated: the scoped finder's miss"
    post claim, headers: bearer(@credential.secret)
    assert_response :unauthorized

    commit = agent_api_v1_executor_inbox_commit_path(run_public_id: loop_id, task_key: "t")
    post commit, headers: bearer(@transport.secret), as: :json, params: { claim_token: "x" }
    assert_response :not_found
    post commit, headers: bearer(@credential.secret), as: :json, params: { claim_token: "x" }
    assert_response :unauthorized
  end

  test "the family never accepts a browser cookie or an admin platform token" do
    sign_in_as users(:owner)
    get agent_api_v1_profile_path
    assert_response :unauthorized

    admin = create_access_token_fixture(user: users(:owner), name: "Admin", plane: :platform)
    get agent_api_v1_profile_path, headers: bearer(admin.secret)
    assert_response :unauthorized
  end

  # Rails accepts all three header shapes as the same credential, so transport spelling cannot
  # multiply its per-resource budget. The source address is deliberately shared to prove a NAT does
  # not pool valid callers.
  test "native header variants share one credential budget without pooling callers" do
    limit = AgentAPI::V1::BaseController::RATE_LIMIT
    variants = authorization_variants(@credential.secret)

    prime_caller_rate_limit(count: limit - 1) do
      variants.each do |authorization|
        get agent_api_v1_profile_path, headers: {
          "Authorization" => authorization, "REMOTE_ADDR" => NAT_ADDRESS,
        }
        assert_response :success
      end
    end

    get agent_api_v1_profile_path, headers: {
      "Authorization" => variants.first,
      "REMOTE_ADDR" => NAT_ADDRESS,
    }
    assert_response :success, "the last request inside the caller budget is admitted"
    variants.each do |authorization|
      get agent_api_v1_profile_path, headers: {
        "Authorization" => authorization, "REMOTE_ADDR" => NAT_ADDRESS,
      }
      assert_response :too_many_requests
      assert_equal "rate_limited", response.parsed_body.dig("error", "code")
      assert_equal AgentAPI::V1::BaseController::RATE_LIMIT_WINDOW.to_i.to_s,
        response.headers["Retry-After"]
    end

    other_credential = create_access_token_fixture(user: users(:owner), name: "Other")
    get agent_api_v1_profile_path, headers: {
      "Authorization" => "Bearer #{other_credential.secret}",
      "REMOTE_ADDR" => NAT_ADDRESS,
    }
    assert_response :success
  end

  # PER RESOURCE, NOT PER FAMILY — the base controller's comment says so and
  # nothing checked it, while the arithmetic it implies is what decides whether
  # an agent that does not subscribe to the realtime stream can afford to
  # follow its own work by polling. One pooled allowance and one
  # allowance per endpoint are very different products, and the difference is
  # invisible until a caller is throttled by requests it never made to that
  # resource.
  test "exhausting one resource's budget leaves the caller's others untouched" do
    limit = AgentAPI::V1::BaseController::RATE_LIMIT

    prime_caller_rate_limit(count: limit) do
      get agent_api_v1_profile_path, headers: bearer(@credential.secret)
      assert_response :success
    end
    get agent_api_v1_profile_path, headers: bearer(@credential.secret)
    assert_response :too_many_requests

    get agent_api_v1_workspaces_path, headers: bearer(@credential.secret)
    assert_response :success,
      "a second resource carries its own budget for the same credential"
  end

  # Ordinary data/control resources share the parallel-work budget. Replay
  # shares that headroom and progress has more; rendered representations retain a lower
  # CPU budget. Exact-claim reads keep their independent polling budget.
  test "each resource declares the rate it can live with" do
    assert_equal 6000, AgentAPI::V1::BaseController::RATE_LIMIT
    assert_equal 6000, AgentAPI::V1::ProfilesController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::InferenceRequestsController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::EventsController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::InferenceRequests::EventsController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Profiles::StoreEntriesController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::StoreEntriesController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::Conversations::StoreEntriesController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Workspaces::InferenceRequests::CancellationsController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Executors::ClaimsController.caller_rate_limit
    assert_equal 600, AgentAPI::V1::Executors::ClaimsController::CLAIM_READ_RATE_LIMIT
    assert_equal 10_000, AgentAPI::V1::Executors::ProgressController.caller_rate_limit
    # The representation reads render through vips/poppler/ffmpeg on a
    # first read: their budget is BELOW the ceiling (audit sec-10).
    assert_equal 30, AgentAPI::V1::Uploads::ThumbnailsController.caller_rate_limit
    assert_equal 30, AgentAPI::V1::Uploads::PreviewsController.caller_rate_limit
    assert_equal 6000, AgentAPI::V1::Uploads::BytesController.caller_rate_limit,
      "the bytes read streams what is stored; it renders nothing"
  end

  test "parallel-work reads serve past the former low caller budget" do
    workspace = workspaces(:shared)
    path = "/agent_api/v1/workspaces/#{workspace.public_id}/inference_requests"
    121.times do
      get path, headers: bearer(@credential.secret)
      assert_response :success
    end
  end

  test "application store mutations use their declared budget and still stop at it" do
    entry = users(:member).store_entries.create!(namespace: "channel", key: "state", value: {})
    path = "/agent_api/v1/profile/store_entries/#{entry.public_id}"
    limit = AgentAPI::V1::Profiles::StoreEntriesController.caller_rate_limit
    prime_caller_rate_limit(count: limit - 1) do
      121.times do |version|
        patch path, headers: bearer(@credential.secret),
          params: { store_entry: { lock_version: version, value: { offset: version } } }, as: :json
        assert_response :success
      end
    end
    patch path, headers: bearer(@credential.secret),
      params: { store_entry: { lock_version: 121, value: { offset: 121 } } }, as: :json
    assert_response :success
    patch path, headers: bearer(@credential.secret),
      params: { store_entry: { lock_version: 122, value: {} } }, as: :json
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal({ "offset" => 121 }, entry.reload.value)
    assert_equal 122, entry.lock_version
  end

  test "event replay admits its configured budget and then throttles" do
    workspace = workspaces(:shared)
    conversation = Conversation.create!(workspace: workspace, creating_user: users(:member), answering_user: @member)
    path = "/agent_api/v1/workspaces/#{workspace.public_id}/conversations/#{conversation.public_id}/events"
    limit = AgentAPI::V1::Workspaces::EventsController.caller_rate_limit
    prime_caller_rate_limit(count: limit - 1) do
      get path, headers: bearer(@credential.secret)
      assert_response :success
    end
    get path, headers: bearer(@credential.secret)
    assert_response :success
    get path, headers: bearer(@credential.secret)
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
    assert_equal "60", response.headers["Retry-After"]
  end

  test "rate limit cache keys never contain raw credential material" do
    raw_header = %(Token token="#{@credential.secret}", nonce="cache-key-regression")

    keys = capture_rate_limit_keys do
      get agent_api_v1_profile_path, headers: { "Authorization" => raw_header }
    end

    assert_response :success
    assert_equal 2, keys.length,
      "one key is the broad IP backstop and one is the normal caller budget"
    keys.each do |key|
      refute_includes key, @credential.secret
      refute_includes key, raw_header
    end
  end

  test "missing and invalid credentials share the source IP budget" do
    same_ip_keys = capture_rate_limit_keys do
      get agent_api_v1_profile_path, headers: { "REMOTE_ADDR" => NAT_ADDRESS }
      assert_response :unauthorized

      [
        "Bearer invalid-credential-one",
        %(Token token="invalid-credential-two", nonce="ignored"),
      ].each do |raw_header|
        get agent_api_v1_profile_path, headers: {
          "Authorization" => raw_header,
          "REMOTE_ADDR" => NAT_ADDRESS,
        }
        assert_response :unauthorized
      end
    end

    assert_equal 6, same_ip_keys.length
    assert_equal 2, same_ip_keys.uniq.length,
      "missing and invalid credentials share both IP-keyed counters"

    other_ip_keys = capture_rate_limit_keys do
      get agent_api_v1_profile_path, headers: { "REMOTE_ADDR" => "203.0.113.24" }
    end

    assert_response :unauthorized
    assert_equal 2, other_ip_keys.length
    assert_empty other_ip_keys & same_ip_keys
  end

  test "a fenced credential is 401 before any composition runs" do
    users(:member).suspend

    get agent_api_v1_profile_path, headers: bearer(@credential.secret)
    assert_response :unauthorized
  end

  private

    def bearer(secret)
      { "Authorization" => "Bearer #{secret}" }
    end

    def authorization_variants(secret)
      [
        "Bearer #{secret}",
        ActionController::HttpAuthentication::Token.encode_credentials(secret),
        %(bEaReR token="#{secret}", nonce="same-client"),
      ]
    end
end
