require "cybros_agent"

# The Nexus side of every rho test: the OAuth wire and the Agent API, scripted.
# They live here rather than inside one test class because three test files
# drive them, and a fake reached through another test's constant is a fake that
# breaks on load order.
module NexusDoubles
  MEMBER_TOKEN = "sk-cybros-api-v1-member.secret".freeze
  TRANSPORT_TOKEN = "sk-cybros-api-v1-transport.secret".freeze
  # The in-process runner's transport credential: the second
  # lineage a combined consume mints, and the one lineage a runner-mode
  # ceremony (branch B) mints.
  RUNNER_TOKEN = "sk-cybros-api-v1-runner.secret".freeze
  RUNNER_REFRESH_TOKEN = "rt-cybros-api-v1-r.s".freeze

  # A kernel task catalog as `/tools` answers it —
  # keyed by the canonical names a settings file writes to declare exactly
  # those; the fake serves the same definition shape as Nexus.
  KERNEL_TOOLS = { "nexus.graph.delegate_task" => "delegate_task" }.freeze
  KERNEL_CATALOG = KERNEL_TOOLS.map do |canonical, name|
    { "canonical_name" => canonical, "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function",
                        "function" => { "name" => name, "description" => "the #{name} verb",
                                        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze

  # The trace a halted run shows: two rounds failed and unresolved, one
  # already abandoned, and a tool call the sweep settled `uncertain` — its
  # executor expired with no result. The kernel's adjudicable
  # rule picks the two unresolved rounds and the uncertain call, and
  # nothing else.
  HALTED_TRACE = {
    "public_id" => "al-9", "status" => "needs_attention",
    "tasks" => [
      { "key" => "round1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed",
        "on_failure" => "halt", "visibility" => "visible",
        "created_at" => "2026-09-04T00:00:00Z" },
      { "key" => "round2", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "timed_out",
        "on_failure" => "halt", "visibility" => "visible",
        "created_at" => "2026-09-04T00:00:00Z" },
      { "key" => "round3", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed",
        "failure_resolution" => "abandoned",
        "on_failure" => "halt", "visibility" => "visible",
        "created_at" => "2026-09-04T00:00:00Z" },
      { "key" => "round4", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "uncertain",
        "tool_name" => "bash", "error" => { "key" => "tool_uncertain" },
        "on_failure" => "halt", "visibility" => "visible",
        "created_at" => "2026-09-04T00:00:00Z" },
    ],
    "attention" => { "reason" => "halt_failure" },
    "created_at" => "2026-09-04T00:00:00Z", "updated_at" => "2026-09-04T00:00:00Z",
  }.freeze

  # A run mid-work with one deliverable, for the verbs that only need a
  # live run to act on.
  RUNNING_TRACE = {
    "public_id" => "al-9", "status" => "running", "deliverable_task_key" => "work",
    "tasks" => [
      { "key" => "work", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "running",
        "on_failure" => "halt", "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z" },
    ],
    "created_at" => "2026-09-05T00:00:00Z", "updated_at" => "2026-09-05T00:00:00Z",
  }.freeze

  # ONE ANNOUNCED ENTRY, as the kernel stores it: the five effect
  # keys, the declaration facts an agent reads to author from a runner it
  # did not load, and an optional park of its own.
  def self.served_tool(name, description: "the #{name} tool", timeout_ms: nil, schema: nil)
    { "name" => name,
      "effect_profile" => { "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
                            "idempotency" => "intrinsic", "reconciliation" => "none" },
      "timeout_ms" => timeout_ms, "description" => description,
      "input_schema" => schema || { "type" => "object", "properties" => {} } }.compact
  end

  # The time the fake kernel "holds" on a timed row: an absolute
  # `deliver_at` as given, a `deliver_in` resolved to one fixed stamp
  # (the fake has no clock), nil on an untimed row.
  def self.scheduled_at(fields)
    fields["deliver_at"] || ("2026-09-16T09:20:00Z" if fields["deliver_in"])
  end

  # One queued row in the projection the SDK reads strictly:
  # what `GET …/inputs` serves for a parked or waiting input.
  # Every input row names its addressee and its author: the
  # fake's own user on both unless a test says otherwise.
  def self.input_row(public_id, state, text: nil, kind: "direct_reply", blocked_reason: nil, origin: "person",
                     queue_position: 0, answering_user_public_id: "0199-user")
    { "public_id" => public_id, "queue_position" => queue_position, "state" => state, "kind" => kind,
      "role" => "user", "delivery_mode" => "queue", "text" => text, "blocked_reason" => blocked_reason,
      "origin" => origin, "lock_version" => 0, "created_at" => "2026-09-06T00:00:00Z",
      "answering_user_public_id" => answering_user_public_id, "speaker" => speaker_row("0199-user") }.compact
  end

  def self.speaker_row(user_public_id)
    { "user_public_id" => user_public_id, "handle" => "rho", "kind" => "agent", "display_name" => "rho" }
  end

  # A RUNNER SOMEWHERE ELSE, as discovery lists it: a
  # `user_private` runner-kind row with the tools it announced and the
  # environment snapshot it announced — the root and the one fragment a
  # remote lead is rendered from — with its presence for display.
  # `root`, `branch` and `worktree` are the announced environment's tree
  # facts; nil is unannounced.
  # `booted_at` is rho's own fact in the opaque document: the process life a host keys its re-assertion on; nil
  # is a runner announcing none.
  def self.remote_runner(public_id, tools: [served_tool("slow_read"), served_tool("slow_write")],
                         root: "/srv/elsewhere", branch: nil, worktree: nil, display_name: "Elsewhere",
                         presence: "online", last_seen_at: nil, kind: "runner", documents: [], booted_at: nil)
    environment = { "root" => root, "branch" => branch, "worktree" => worktree, "booted_at" => booted_at }.compact
    environment["fragments"] = [{ "extension" => "e2e.echo", "text" => "Relative paths resolve against #{root}." }] if root
    { "public_id" => public_id, "kind" => kind, "display_name" => display_name, "status" => "active",
      "assignment_scope" => "user_private", "served_tools" => tools, "environment" => environment,
      "served_documents" => documents,
      "presence" => presence, "last_seen_at" => last_seen_at, "connected_at" => nil }.compact
  end

  # The OAuth wire: device authorization, then a poll that wins immediately.
  # EACH AUTHORIZATION REMEMBERS ITS BRANCH by the claims it carried (the
  # agent triple, the runner pair, or both), and the token poll answers in
  # that branch's shape: the combined body carries the nested `runner`
  # object exactly as `render_token` emits it, a runner-only body is
  # transport-led. `plane:`/`with_executor:` script the agent body for the
  # tests that want a malformed one.
  class FakeOAuth
    USER_CODES = %w[BCDF-GHJK CDFG-HJKL DFGH-JKLM FGHJ-KLMN GHJK-LMNP].freeze

    attr_reader :requests, :revocations

    def initialize(plane: "member", with_executor: true)
      @plane = plane
      @with_executor = with_executor
      @requests = []
      @revocations = []
      @authorization_sequence = 0
      @authorizations = {}
      @branches = {}
    end

    # The shared transport contract (CybrosAgent::Transport); tests hook the
    # wire at `post`, the grain the OAuth ceremony speaks.
    def call(path, method:, form:, timeout:)
      raise ArgumentError, "the OAuth wire is POST" unless method == :post

      post(path, form, timeout: timeout)
    end

    def post(path, params, timeout:)
      @requests << [path, params]
      case path
      when "/oauth/device_authorization"
        respond(200, authorization(params))
      when "/oauth/token"
        token_response(params)
      when "/oauth/device_authorization/cancellation"
        cancellation_response(params)
      when "/oauth/revoke"
        @revocations << params[:token]
        respond(200, nil)
      else raise "unexpected #{path}"
      end
    end

    # The branch each authorization was asked for, oldest first.
    def branches = @branches.values

    private

      def authorization(params)
        @authorization_sequence += 1
        device_code = "dc-cybros-v1-abc.#{@authorization_sequence}"
        @authorizations[device_code] = :pending
        @branches[device_code] = branch_of(params)
        user_code = USER_CODES.fetch((@authorization_sequence - 1) % USER_CODES.length)
        {
          "device_code" => device_code, "user_code" => user_code,
          "verification_uri" => "https://nexus.example/oauth/device",
          "verification_uri_complete" => "https://nexus.example/oauth/device?user_code=#{user_code}",
          "interval" => 5, "expires_in" => 900,
        }
      end

      def branch_of(params)
        if params[:registration_identifier] && params[:agent_identifier] then :combined
        elsif params[:registration_identifier] then :runner
        else :agent
        end
      end

      def token_response(params)
        unless params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
          return respond(200, params[:refresh_token].to_s.start_with?("rt-cybros-api-v1-r") ? runner_token : token)
        end

        state = @authorizations[params[:device_code]]
        return respond(400, { "error" => "access_denied" }) if state == :canceled

        @authorizations[params[:device_code]] = :consumed
        case @branches[params[:device_code]]
        when :combined then respond(200, token.merge("runner" => runner_half))
        when :runner then respond(200, runner_token)
        else respond(200, token)
        end
      end

      def cancellation_response(params)
        state = @authorizations[params[:device_code]]
        if state == :consumed
          respond(409, { "error" => "too_late" })
        else
          @authorizations[params[:device_code]] = :canceled
          respond(200, nil)
        end
      end

      def respond(status, body)
        Data.define(:status, :headers, :body).new(status: status, headers: {}, body: body)
      end

      def token
        body = {
          "access_token" => @plane == "member" ? MEMBER_TOKEN : TRANSPORT_TOKEN,
          "plane" => @plane, "refresh_token" => "rt-cybros-api-v1-a.b",
          "token_type" => "Bearer", "expires_in" => 1_209_600,
        }
        body["executor_access_token"] = TRANSPORT_TOKEN if @with_executor && @plane == "member"
        body
      end

      # Branch B's transport-led shape, on the runner's own lineage.
      def runner_token
        {
          "access_token" => RUNNER_TOKEN, "plane" => "executor_transport",
          "refresh_token" => RUNNER_REFRESH_TOKEN, "token_type" => "Bearer", "expires_in" => 1_209_600,
        }
      end

      def runner_half = { "access_token" => RUNNER_TOKEN, "refresh_token" => RUNNER_REFRESH_TOKEN }
  end

  # An Agent API whose acceptance of each plane can be turned off
  # independently — the state Round D deliberately made legal: a dead member
  # plane beside a live delivery address, or the reverse. It lives here and
  # not in the test class that first needed it, per the header above — two
  # files drive it, and a daemon test run on its own must not depend on
  # `authority_test.rb` having been loaded first.
  class SelectiveApi
    attr_reader :calls

    def initialize(accept: { MEMBER_TOKEN => true, TRANSPORT_TOKEN => true, RUNNER_TOKEN => true })
      @accept = { RUNNER_TOKEN => true }.merge(accept)
      @calls = []
    end

    def accept(credential, allowed) = @accept[credential] = allowed

    def call(path, method: :get, credential: nil, body: nil, params: nil, headers: {}, timeout:)
      @calls << [path, credential]
      unless @accept[credential]
        return CybrosAgent::Response.new(
          status: 401, headers: {},
          body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }
        )
      end

      # Acceptance is decided here, by credential; the shape of an accepted
      # answer comes from the ordinary fake, which keys on the plane's own
      # token rather than on whatever we happen to be holding today — the
      # executor plane by the token presented, so the runner's row answers
      # the runner's credential.
      plane_token =
        if path.start_with?(EXECUTOR_PLANE)
          credential == RUNNER_TOKEN ? RUNNER_TOKEN : TRANSPORT_TOKEN
        else
          MEMBER_TOKEN
        end
      FakeAgentApi.new.call(
        path, method: method, credential: plane_token,
        body: body, params: params, headers: headers, timeout: timeout
      )
    end
  end

  # Everything under this prefix is the executor plane's: the
  # description, the announcement, the inbox and its claim and commit.
  EXECUTOR_PLANE = "/agent_api/v1/executor".freeze
end

require_relative "nexus_doubles/agent_api"
require_relative "nexus_doubles/conversations"
require_relative "nexus_doubles/runs"
require_relative "nexus_doubles/resources"

require_relative "nexus_doubles/tool_assembly"
