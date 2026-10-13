$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/webui"
require "minitest/autorun"
require "rubygems/package"
require "open3"
require "rbconfig"
require "tmpdir"

module WebuiTest
  ROOT = File.expand_path("..", __dir__)

  def registered_root
    root = nil
    api = Object.new
    api.define_singleton_method(:register_webui) { |**options| root = options.fetch(:root) }
    Rho::Webui.register(api)
    root
  end
end
