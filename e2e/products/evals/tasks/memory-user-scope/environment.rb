# ONE hyphen-free token (live_memory_scopes' lesson: a model reads "the
# word" as the part after a hyphen), the seed's secret with a letter prefix.
->(seed) { { "TOKEN.txt" => "zq#{seed.secret}\n" } }
