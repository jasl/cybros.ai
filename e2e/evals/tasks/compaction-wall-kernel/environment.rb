require "securerandom"

# B51'S CORPUS: a wall whose prunable bytes CANNOT cover the overshoot,
# so the arm must SUMMARIZE in kernel mode. The arm prunes when the tool
# RESULTS outside the keep-recent tail cover the overshoot
# (`arm.rb:163-166`); the tail is `min(Σ × 0.25, 80 KiB)` of the RENDERED
# entries (`serialize.rb` `tail_index`) — a 46 KiB read renders as a
# pointer line, so the tail spans ≈ 16 rounds — and tool INPUTS, the
# model's own writes, are never prunable. Each file here is read (a
# ≈ 46 KiB result, prunable) and WRITTEN back with line numbers (a
# ≈ 49 KiB input, not prunable). The RATIONALE carries the arithmetic.
#
# THE ROWS ARE LOW-ENTROPY WORDS, not random alphanumerics. The wall is
# a BYTE wall (1 MiB composed, `input_composition.rb`), so the bytes to
# each wall are the same whatever the rows say — but the model pays per
# TOKEN: random 40-character strings tokenize at ≈ 0.56 tok/B (run 1:
# 590 804 input tokens at ≈ 1 MiB composed, $8.17 and 73 min to wall 1
# on glm-5.3), six words from a fixed 256-word list at ≈ 0.25–0.30 tok/B,
# which halves both the history re-sent every round and the write
# outputs (the run is output-bound). Still ≈ 64 B a row, 720 rows,
# ≈ 46 KiB a file: rho's whole read caps at 50 KiB / 2 000 lines
# (`rho-runner/lib/rho/runner/truncation.rb:14-15`), so a LARGER file is
# impossible, and a smaller one only raises the round count to the same
# wall. The LAST line of every file is a body-only token no command
# writes (`tail-<hex>`), beyond the summary's 200-byte arguments head —
# the pointer rule's probe, untouched by the re-cut. The list is a local
# the lambda closes over (the corpus evaluates this file per load).
words = %w[
  garden silver window bridge castle forest island market meadow orchid pepper rocket saddle timber valley walnut
  yellow anchor basket candle dragon farmer hammer jacket kettle ladder magnet needle office pencil rabbit spider
  tablet turtle velvet wander zipper button cactus desert engine falcon goblet harbor jungle kernel marble nickel
  oyster parcel quiver ribbon summit ticket unfold violet wallet yonder almond beacon carpet dinner effort fabric
  glider helmet insect jigsaw kidney lizard mirror napkin object pillow quartz radish salmon temple umpire vessel
  wizard yogurt zenith bottle canyon damsel emblem fossil gutter hazard ignite jester ledger mantle nozzle oracle
  puzzle quench ripple sponge thrive utmost vortex whisky yearly zombie arcade bamboo cobalt dahlia eleven fiddle
  gentle hearth indigo jumper kitten lumber mellow noodle outlaw parrot quaint rubber shadow tomato unless velcro
  willow xylene yarrow zephyr banner cellar dimple escape flavor gravel hollow invent jingle keeper launch mosaic
  nectar orange pastry random sailor throne unique voyage zigzag abroad bishop copper divine easter fringe ginger
  hurdle infant jockey knight legend mammal nephew osprey pirate quarry remote scarab tunnel unveil vacuum weasel
  bounty cherry dollar embers flight glance heaven inland jovial locust oxygen planet reward stream travel unfair
  virtue winter arrive bright cradle donkey fabled grotto hermit ironic kimono lagoon mantis nutmeg orbits plunge
  quilts rattle sketch tundra uphold vanish wobble yachts abacus binder chorus divert erupts frosty gospel heckle
  ignore jargon knives lively muffin notion oddity pantry quaked rustic sturdy tiptoe uneven vivify wrench alpine
  barrel beetle cinder corner cotton danger dazzle fennel finger garlic goblin jasper lentil lotion melody monkey
].freeze
row_words = 6

lambda do |_seed|
  files = Integer(ENV.fetch("E2E_WALL_KERNEL_FILES", "18"))
  corpus = (1..files).to_h do |i|
    name = format("part-%02d.txt", i)
    body = Array.new((45 * 1024) / 64) do |k|
      "row #{k} of #{name}: #{Array.new(row_words) { words[SecureRandom.random_number(words.size)] }.join(" ")}"
    end
    ["src/#{name}", (body + ["tail-#{SecureRandom.hex(6)} of #{name}"]).join("\n") + "\n"]
  end
  corpus.merge(
    "src/INDEX" => (1..files).map { |i| format("part-%02d.txt", i) }.join("\n") + "\n",
    "out/.keep" => "",
    "check.sh" => <<~SH
      #!/bin/sh
      missing=0
      for f in src/part-*.txt; do
        name=$(basename "$f")
        grep -q "^$name: " INDEX.md 2>/dev/null || { echo "missing: $name"; missing=$((missing + 1)); }
        [ -f "out/$name" ] || { echo "out/$name is not written"; missing=$((missing + 1)); }
      done
      [ "$missing" -eq 0 ] && echo "all #{files} copied and indexed" && exit 0
      echo "$missing files are not done yet"; exit 1
    SH
  )
end
