require_relative "boot"

require "base64"
require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Nexus
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.2

    # Fiber-scoped execution state: Solid Queue's fiber workers require it,
    # and under a threaded server every thread runs on its own root fiber, so
    # per-fiber isolation is strictly finer than per-thread and behaves
    # identically for Puma requests.
    config.active_support.isolation_level = :fiber

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Active Storage draws no routes. Its direct-upload endpoints accept
    # anonymous blob writes and its read routes are public bearer URLs;
    # nothing here mints a signed-id URL, and the only ingest is the member
    # plane's multipart door.
    config.active_storage.draw_routes = false

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Member and executor clients share the versioned API's Cable mount.
    # ApplicationCable::Connection authenticates each credential plane
    # separately; subscriptions admit only their own plane. Browser clients
    # may instead authenticate with the signed member session cookie.
    config.action_cable.mount_path = "/agent_api/v1/cable"

    # SAME-ORIGIN AND ORIGIN-LESS CLIENTS SHARE THIS CABLE.
    #
    # Action Cable refuses an upgrade whose Origin it does not recognize — the
    # check runs on the SERVER, before any Connection code — and out of the box
    # it recognizes only `localhost:<port>` in development and, everywhere
    # else, the app's own host. A non-browser client may send the endpoint's
    # matching HTTP(S) Origin or omit the header; both are valid member-cable
    # shapes.
    #
    # `nil` in this list is what admits them, and it gives up nothing: a
    # browser cannot omit Origin on a WebSocket upgrade, so an origin-less
    # request is never carrying an ambient cookie for a foreign page to ride.
    # Clients that do send Origin still answer to the ordinary same-origin
    # check (`allow_same_origin_as_host`, on by default) plus the development
    # localhost forms kept below.
    #
    # Both member and executor clients use this shared origin policy.
    config.action_cable.allowed_request_origins =
      [nil, %r{\Ahttps?://localhost:\d+\z}, %r{\Ahttps?://127\.0\.0\.1:\d+\z}]

    # THE STREAMER IS ONE THREAD, so a stream is delivered in the order it
    # was broadcast. The transcript feed is not durable and carries no
    # sequence: a follower joins the deltas in arrival order, and the SDK
    # accumulator proves they ARE the sealed body (`streaming_test`). Every
    # pubsub adapter hands each message it reads to this executor — Solid
    # Cable's listener posts a poll's whole batch, read by `id`, one message
    # per post — and Rails main made it a POOL of ten where the older API
    # posted to the single event-loop thread. Two deltas inside one 100 ms
    # poll were then transmitted by two threads, and the second chunk of a
    # reasoning delta reached the socket first (`efullyweighing it up car`,
    # identically on two machines). One thread is FIFO however long a
    # delivery takes; a delivery is a JSON decode and a buffered
    # non-blocking socket write, so the thread is never the wall.
    # `test/configuration/cable_delivery_order_test` pins it against the
    # real adapter.
    config.action_cable.executor_pool_size = 1

    # Disallow permanent checkout of activerecord connections (request scope):
    config.active_record.permanent_connection_checkout = :disallowed

    # JSON null is data. Rails' legacy deep-munge default removes nil members
    # from arrays before controllers see them, which corrupts opaque JSON such
    # as store entry values. Keep the parsed JSON vocabulary intact;
    # each endpoint's boundary still permits and validates its own shape.
    config.action_dispatch.perform_deep_munge = false

    # Use modern header-based CSRF protection (requires Sec-Fetch-Site header support).
    # NOTE: the switch is forgery_protection_VERIFICATION_strategy; the sibling
    # forgery_protection_strategy attribute holds a ProtectionMethods CLASS (set by
    # the framework-default `protect_from_forgery with: :exception`) — assigning the
    # symbol there crashes every verified browser POST with NoMethodError.
    config.action_controller.forgery_protection_verification_strategy = :header_only

    config.i18n.available_locales = %i[en]
    config.i18n.load_path += Dir[Rails.root.join("config", "locales", "**", "*.{rb,yml}")]
    # Fallback to English if translation key is missing
    config.i18n.fallbacks = true

    config.generators do |g|
      g.helper false
      g.assets false
      g.test false
    end

    if Rails.const_defined?(:CodeStatistics)
      Rails::CodeStatistics.register_directory("Services", "app/services")
    end
  end
end
