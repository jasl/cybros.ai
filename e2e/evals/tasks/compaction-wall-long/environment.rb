require "securerandom"

# live_long_session's corpus (`:160-168`): sixty files of forty-five
# kilobytes, read whole one per call, cross the composer's byte wall
# (1 MiB) after two dozen reads. Each file's FIRST line is unique and
# unguessable (the index line); its SECOND line is a body-only token no
# command ever writes (`body-<hex>`): a summary carrying one reproduced a
# value. E2E_LONG_FILES is the lane's smoke knob and the corpus honours it.
lambda do |_seed|
  files = Integer(ENV.fetch("E2E_LONG_FILES", "60"))
  corpus = (1..files).to_h do |i|
    name = format("doc-%03d.txt", i)
    first = "first-line-#{SecureRandom.hex(6)} of #{name}"
    token = "body-#{SecureRandom.hex(6)} of #{name}"
    body = Array.new((45 * 1024) / 64) { |k| "line #{k} of #{name}: #{SecureRandom.alphanumeric(40)}" }
    ["corpus/#{name}", ([first, token] + body).join("\n") + "\n"]
  end
  corpus.merge(
    "corpus/INDEX" => (1..files).map { |i| format("doc-%03d.txt", i) }.join("\n") + "\n",
    "check.sh" => <<~SH
      #!/bin/sh
      missing=0
      for f in corpus/doc-*.txt; do
        name=$(basename "$f")
        grep -q "^$name: " index.txt 2>/dev/null || { echo "missing: $name"; missing=$((missing + 1)); }
      done
      [ "$missing" -eq 0 ] && echo "all #{files} indexed" && exit 0
      echo "$missing files are not in index.txt yet"; exit 1
    SH
  )
end
