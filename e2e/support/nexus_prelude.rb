require_relative "../../nexus/config/boot"
require "rails"

module E2E
  # A world runs one boot of each Nexus process. Reloading during a journey
  # can deadlock a queue worker: the class-unload lock joins the Cable writer,
  # while that writer waits to enter the Rails executor under the same lock.
  # Keep development's HTTP behavior, including CSRF, but verify source edits
  # in a new world instead of replacing classes inside a running one.
  class NexusRuntime < Rails::Railtie
    config.before_initialize do |app|
      app.config.enable_reloading = false
    end
  end
end
