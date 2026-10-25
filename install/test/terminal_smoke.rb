require "rho/env"
require "rho/env/extensions/terminal"
require "rho/env/webrtc_transport"

# Exercise the image's bundled helper with the plugin's empty default config.
loaded = Rho::Env::Extensions::Loader.call(builtin: [Rho::Env::Extensions::Terminal])
abort "Terminal plugin could not load the bundled helper" unless loaded.ok?
abort "Terminal tool was not announced" unless loaded.registry.names.include?("terminal")
peer = Rho::Env::WebrtcTransport.new(executable: Rho::Env::Extensions::Terminal::BUNDLED_EXECUTABLE)
begin
  abort "Terminal helper did not produce a data-channel offer" unless peer.offer.include?("m=application")
  puts "Bundled terminal helper loaded and produced a WebRTC offer"
ensure
  peer.close
end
