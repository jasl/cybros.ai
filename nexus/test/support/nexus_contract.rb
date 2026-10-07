require "yaml"

module Nexus
  # Test-owned deterministic cross-process wire fixture generator. The pack covers
  # only public JSON surfaces that currently ship; planned Task protocols join
  # when their routes and producers exist.
  module Contract
    VERSION = "nexus/v1".freeze
    UNKNOWN_VERSION_FIXTURE = "nexus/v999".freeze
    UNKNOWN_VALUE_FIXTURE = "zz_unknown_value".freeze
    # The one staged upload every upload fixture names: the descriptor the doors answer and the
    # capture a commit links.
    UPLOAD_PUBLIC_ID = "01900000-0000-7000-8000-000000000040".freeze
    # The ONE `GET /tools` entry the tools pack carries as `Entry#template`'s
    # settled fixture: the template the gem's `claude` recut anchors on, so a
    # re-cut of any other description regenerates nothing.
    TOOLS_FIXTURE_ENTRY = "nexus.graph.delegate_task".freeze

    class << self
      # The pack is the WIRE: every producer's projection passes through
      # the same JSON encoding a response does (whole-second timestamps,
      # config/initializers/json.rb), so a fixture never carries a Ruby
      # value the wire would spell differently.
      def pack
        {
          "meta.json" => meta,
          "coverage.json" => coverage,
          "credentials.json" => credentials,
          "oauth.json" => oauth,
          "sessions.json" => sessions,
          "profiles.json" => profiles,
          "users.json" => users,
          "task_executors.json" => task_executors,
          "executor_inbox.json" => executor_inbox,
          "executor_operations.json" => executor_operations,
          "uploads.json" => uploads,
          "size_bounds.json" => size_bounds,
          "content_addressing.json" => content_addressing,
          "errors.json" => errors,
          "workspaces.json" => workspaces,
          "store_entries.json" => store_entries,
          "prompt_documents.json" => prompt_documents,
          "memory_documents.json" => memory_documents,
          "inference_requests.json" => inference_requests,
          "conversations.json" => conversations,
          "schedules.json" => schedules,
          "history.json" => history,
          "runs.json" => agent_runs,
          "admin_users.json" => admin_users,
          "tools.json" => tools,
          "models.json" => models,
        }.as_json
      end

      def render(data)
        JSON.pretty_generate(data) << "\n"
      end

      # The manifest names the pack's contract version and its complete file
      # set — the two facts a consumer cannot get from the directory alone
      # (it can list files, but not know whether the list is complete). It
      # carries no digests: the pack's authority is the GENERATOR, and
      # Nexus::ContractTest compares every committed byte against freshly
      # rendered output from the shipped code in the same CI run, which
      # catches a hand-edited pack file with an actionable message.
      def manifest(rendered_pack)
        {
          "contract" => VERSION,
          "files" => rendered_pack.keys.sort,
        }
      end

      private

        def meta
          {
            "contract" => VERSION,
            "unknown_version_fixture" => UNKNOWN_VERSION_FIXTURE,
            "unknown_version_behavior" => "reject",
            "unknown_value_fixture" => UNKNOWN_VALUE_FIXTURE,
            "unknown_behavior_is_per_shape" => true,
          }
        end

        def stringify_keys(value)
          case value
          when Hash
            value.to_h { |key, item| [key.to_s, stringify_keys(item)] }
          when Array
            value.map { |item| stringify_keys(item) }
          else
            value
          end
        end

        # The inspection read's one shape (AgentAPI::SealedRequestPresenter):
        # two keys, the payloads verbatim.
        def sealed_request_fixture(entries:, request_options:)
          { "request" => { "entries" => entries, "request_options" => request_options } }
        end
    end
  end
end

require_relative "nexus_contract/coverage"
require_relative "nexus_contract/identity"
require_relative "nexus_contract/tools"
require_relative "nexus_contract/executors"
require_relative "nexus_contract/content"
require_relative "nexus_contract/errors"
require_relative "nexus_contract/workspaces"
require_relative "nexus_contract/models"
require_relative "nexus_contract/documents"
require_relative "nexus_contract/conversations"
require_relative "nexus_contract/schedules"
require_relative "nexus_contract/conversation_fixtures"
require_relative "nexus_contract/inference_requests"
require_relative "nexus_contract/agent_runs"
require_relative "nexus_contract/executor_operations"

require_relative "nexus_contract/history"
