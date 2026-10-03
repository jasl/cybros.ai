# THE OPT-IN REALTIME CLIENT. Deliberately NOT loaded by `require
# "cybros_agent"` — it rides the async websocket stack, which is not a runtime
# dependency of this gem and is not going to become one. A program that
# follows a run over HTTP needs none of it, and `CybrosAgent::KernelFeed` is
# that program's whole answer.
#
# A consumer that wants the socket adds the gem and requires this file:
#
#   # Gemfile: gem "async-websocket"
#   require "cybros_agent/realtime"
#
#   Async do
#     realtime = CybrosAgent::Realtime::Client.new(endpoint: endpoint)
#     realtime.connect
#     subscription = realtime.subscribe(
#       channel: "AgentAPI::V1::OneShotEventsChannel",
#       params: { workspace_id: workspace.public_id, one_shot_id: run.public_id }
#     )
#     subscription.each { |message| handle(message.fetch("event")) }
#   end
#
# The ERROR types are not here: they load with the base gem, so a feed can
# recognize a lost connection without any of this.
require_relative "../cybros_agent"

module CybrosAgent
  module Realtime
    # The executor's own channel, ONE per executor and no params:
    # the subscription this client answers the server's pings on — the kernel's pong expectation closes a socket that stops.
    EXECUTOR_INBOX_CHANNEL = "AgentAPI::V1::ExecutorInboxChannel".freeze

    # Required at load time rather than lazily, so a missing gem is a startup
    # failure with an actionable message instead of a LoadError from inside a
    # reactor three frames deep. The loader is injectable so the missing-gem
    # path is testable without uninstalling anything.
    REQUIRED_LIBRARIES = [
      "async",
      "async/queue",
      "async/semaphore",
      "async/websocket",
      "async/http/endpoint",
    ].freeze

    def self.require_dependencies(loader = Kernel.method(:require))
      REQUIRED_LIBRARIES.each { |library| loader.call(library) }
    rescue LoadError => error
      raise CybrosAgent::Error,
            "CybrosAgent::Realtime requires the async-websocket gem " \
            "(#{error.message}). It is an optional dependency — add " \
            "`gem \"async-websocket\"` to your Gemfile to use the realtime client."
    end
  end
end

CybrosAgent::Realtime.require_dependencies

require_relative "realtime/protocol"
require_relative "realtime/endpoint"
require_relative "realtime/subscription"
require_relative "realtime/client"
require_relative "realtime/feed_subscription"
