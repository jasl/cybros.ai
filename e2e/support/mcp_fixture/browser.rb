# THE `$BROWSER` STUB: what a person's browser does in `rho mcp login`, without a person — `ruby
# browser.rb URL` GETs the authorization URL rho printed (the mock AS auto-consents and answers a
# 302) and GETs the `Location` it answers, which is the verb's own loopback callback. Prints
# nothing, exits 0: rho's launcher (`Rho::Cli::Browser`) honours `$BROWSER` by appending the URL,
# detaches the opener and never reads its exit, so a failure here is what it would be with a real
# browser — a login the verb times out on and names.
require "net/http"
require "uri"

url = ARGV.fetch(0)
begin
  answer = Net::HTTP.get_response(URI(url))
  location = answer["location"] if answer.is_a?(Net::HTTPRedirection)
  Net::HTTP.get_response(URI(location)) if location
rescue StandardError
  nil
end
exit 0
