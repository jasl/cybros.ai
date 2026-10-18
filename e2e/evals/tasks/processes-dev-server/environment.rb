# The port is the seed's (free when minted); the content carries the
# seed's secret so the reply cannot be guessed.
lambda do |seed|
  { "PORT" => "#{seed.port}\n",
    "hello.txt" => "hello from the project #{seed.secret}\n",
    "serve.sh" => "#!/bin/sh\nexec python3 -m http.server \"$(cat PORT)\" --bind 127.0.0.1\n" }
end
