require "securerandom"
require "shellwords"

# THE LONG FIXTURE, GENERATED PER RUN (live_exit_long_test.rb:265-372,
# moved here as the ONE fixture source: the lane reads this lambda too).
# The vector corpus crosses the byte wall twice when read whole (the
# sizing rule in the lane's header: 56 × 45 KiB > 2 × 1 MiB + 2 × 80 KiB
# + the port's reads); E2E_EXIT_LONG_VECTORS=12 is the lane's smoke and
# the corpus honours the same knob. The SPEC-TOKEN is the seed's secret,
# written OUTSIDE the project root (`<home>/spec-seed`) where the read
# tool cannot reach it; the server reads it, the gate compares it. The
# server's port is the seed's, in `server/PORT` (an explicit ARGV wins,
# so the lane's own text may still pass it).
lambda do |seed|
  vectors = Integer(ENV.fetch("E2E_EXIT_LONG_VECTORS", "56"))
  vector_bytes = 45 * 1024
  seed_path = File.join(seed.home, "spec-seed")
  File.write(seed_path, "#{seed.secret}\n")
  files = (1..vectors).to_h do |i|
    name = format("vec-%02d.txt", i)
    first = "vector-#{SecureRandom.hex(6)} of #{name}"
    body = Array.new(vector_bytes / 64) { |k| "frame #{k} of #{name}: #{SecureRandom.alphanumeric(40)}" }
    marker = "marker-#{SecureRandom.hex(6)} of #{name}"
    at = SecureRandom.random_number(body.size + 1)
    last = "vector-end-#{SecureRandom.hex(6)} of #{name}"
    ["spec/vectors/#{name}", ([first] + body[0, at] + [marker] + body[at..] + [last]).join("\n") + "\n"]
  end
  files.merge(
    "spec/vectors/INDEX" => (1..vectors).map { |i| format("vec-%02d.txt", i) }.join("\n") + "\n",
    "server/PORT" => "#{seed.port}\n",
    "test/spec_token_test.rb" => <<~'RUBY',
      require "minitest/autorun"
      require "frame_codec"

      # The spec server (server/app.rb) prints the token this codec is
      # keyed to; the port carries it as FrameCodec::SPEC_TOKEN.
      class SpecTokenTest < Minitest::Test
        def test_the_spec_token_is_sixteen_hex_digits
          assert_match(/\A\h{16}\z/, FrameCodec::SPEC_TOKEN.to_s)
        end
      end
    RUBY
    "test/all.rb" => "Dir[File.join(__dir__, \"*_test.rb\")].sort.each { |file| require file }\n",
    "server/app.rb" => <<~RUBY,
      # The spec server: prints the token this codec's specification is
      # keyed to, then serves /health until it is stopped. The port is the
      # first argument, or server/PORT beside this file.
      require "webrick"

      port = Integer(ARGV[0] || File.read(File.join(__dir__, "PORT")).strip)
      $stdout.sync = true
      server = WEBrick::HTTPServer.new(Port: port, BindAddress: "127.0.0.1",
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: [])
      server.mount_proc("/health") { |_request, response| response.body = "ok\\n" }
      puts "listening on " + port.to_s
      # THE TOKEN ARRIVES AFTER THE READY LINE, on purpose: start_process
      # answers with the output so far when wait_for matches
      # (processes/tools.rb `answer`), so a token printed first would ride
      # that answer and read_process would prove nothing.
      Thread.new { sleep 3; puts "SPEC-TOKEN: " + File.read(#{seed_path.inspect}).strip }
      server.start
    RUBY
    "check.sh" => <<~SH,
      #!/bin/sh
      # The acceptance gate: the vector index complete and exact (each
      # line the file's first line AND its marker line), the server's
      # token in the port, the suite green.
      missing=0
      for f in spec/vectors/vec-*.txt; do
        name=$(basename "$f")
        want="$name: $(head -n 1 "$f") | $(grep -m1 -- '^marker-' "$f")"
        grep -qxF -- "$want" VECTORS.md 2>/dev/null || { echo "missing or wrong in VECTORS.md: $name"; missing=$((missing + 1)); }
      done
      [ "$missing" -eq 0 ] || { echo "$missing vector files are not in VECTORS.md yet (each line: first line | marker line)"; exit 1; }
      [ -f lib/frame_codec.rb ] || { echo "lib/frame_codec.rb does not exist yet"; exit 1; }
      token=$(cat #{Shellwords.escape(seed_path)})
      ruby -Ilib -e 'require "frame_codec"; exit(FrameCodec::SPEC_TOKEN == ARGV[0] ? 0 : 1)' "$token" 2>/dev/null \\
        || { echo "FrameCodec::SPEC_TOKEN is not the token server/app.rb prints (start it with start_process and read its output)"; exit 1; }
      ruby -Ilib -Itest test/all.rb
    SH
    "PORT.md" => <<~'MD'
      # Port brief

      Port `src/frame_codec.js` to Ruby as `lib/frame_codec.rb`, so that
      `ruby -Ilib -Itest test/all.rb` passes. The tests are the
      specification: read them before the JavaScript.

      The Ruby shape the tests use:

      | JavaScript                                   | Ruby                                                                   |
      |----------------------------------------------|------------------------------------------------------------------------|
      | `encodeVarint(n)` → Uint8Array               | `FrameCodec.encode_varint(n)` → binary String                          |
      | `decodeVarint(bytes, offset)` → {value, next} | `FrameCodec.decode_varint(bytes, offset = 0)` → `[value, next_offset]` |
      | `crc16(bytes)`                               | `FrameCodec.crc16(bytes)` → Integer                                    |
      | `escape` / `unescape`                        | `FrameCodec.escape` / `FrameCodec.unescape`                            |
      | `encodeFrame(kind, payload)`                 | `FrameCodec.encode_frame(kind, payload)`                               |
      | `decodeFrames(bytes)` → results              | `FrameCodec.decode_frames(bytes)` → Array                              |
      | `{ok: true, kind, payload}`                  | `FrameCodec::Frame.new(kind:, payload:)` (a Data)                      |
      | `{ok: false, reason, skipped}`               | `FrameCodec::Damaged.new(reason:, skipped:)` (a Data)                  |
      | `FrameReader` (`feed`, `pending`, `reset`)   | `FrameCodec::Reader` (`feed`, `pending`, `reset`)                      |
      | `VarintError`, `EscapeError`                 | `FrameCodec::VarintError`, `FrameCodec::EscapeError`                   |
      | `RangeError` from `encodeFrame`              | `ArgumentError`                                                        |
      | `MAX_PAYLOAD`, `MAX_SEGMENT_BYTES`           | `FrameCodec::MAX_PAYLOAD`, `FrameCodec::MAX_SEGMENT_BYTES`             |

      Bytes are binary Strings (`String#b`, `getbyte`, `pack("C*")`) at the
      API boundary, never Arrays of Integers.

      `FrameCodec::SPEC_TOKEN` is the token the spec server prints
      (`ruby server/app.rb` → `SPEC-TOKEN: …`).
    MD
  )
end
