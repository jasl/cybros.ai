module E2E
  module JourneyGroups
    module_function

    # The flat union, in group order — the serial task's list.
    def journeys
      GROUPS.values.flatten
    end

    def paths(files)
      files.map { |name| "test/#{name}_test.rb" }
    end

    # The groups, heaviest first.
    def spawn_order(weights: WEIGHTS)
      GROUPS.keys.sort_by { |key| [-weights.fetch(key), key] }
    end

    def validate!(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS, optional: REALTIME, diagnostics: DIAGNOSTICS)
      problems = violations(harness: harness, groups: groups, test_dir: test_dir, weights: weights, optional: optional, diagnostics: diagnostics)
      return if problems.empty?

      raise ArgumentError, "journey manifest: #{problems.join("; ")}"
    end

    # Every rule, as a sentence naming the file, so a refusal says what to
    # move rather than that something is wrong.
    def violations(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS, optional: REALTIME, diagnostics: DIAGNOSTICS)
      listed = harness + groups.values.flatten + optional + diagnostics
      [
        *missing_files(listed, test_dir),
        *duplicates(listed),
        *unlisted(listed, test_dir),
        *doubled_ceremony_files(groups),
        *writer_beside_reader(groups, test_dir),
        *unweighted(groups, weights),
      ]
    end

    def unweighted(groups, weights)
      return [] if groups.keys.sort == weights.keys.sort

      ["WEIGHTS names #{weights.keys.sort.inspect} but the groups are #{groups.keys.sort.inspect}"]
    end

    def missing_files(listed, test_dir)
      listed.reject { |name| File.file?(File.join(test_dir, "#{name}_test.rb")) }
        .map { |name| "#{name} is listed but test/#{name}_test.rb does not exist" }
    end

    def duplicates(listed)
      listed.tally.select { |_name, count| count > 1 }
        .map { |name, count| "#{name} is listed #{count} times" }
    end

    def unlisted(listed, test_dir)
      Dir.children(test_dir).sort
        .filter_map { |file| file.delete_suffix("_test.rb") if file.end_with?("_test.rb") }
        .reject { |name| listed.include?(name) }
        .map { |name| "test/#{name}_test.rb is in no group and not a harness test" }
    end

    def doubled_ceremony_files(groups)
      groups.filter_map do |key, files|
        doubled = files & ONE_PER_GROUP
        "group #{key} holds #{doubled.join(" and ")}; one of #{ONE_PER_GROUP.join("/")} per group" if doubled.size > 1
      end
    end

    def writer_beside_reader(groups, test_dir)
      groups.flat_map do |key, files|
        writers = files & SHARED_HUMAN_WRITERS
        next [] if writers.empty?

        (files - SHARED_HUMAN_WRITERS).select { |name| shared_human_reader?(name, test_dir) }
          .map { |name| "group #{key} holds the shared_human writer #{writers.join("/")} beside the reader #{name}" }
      end
    end

    def shared_human_reader?(name, test_dir)
      path = File.join(test_dir, "#{name}_test.rb")
      File.file?(path) && File.read(path, encoding: Encoding::UTF_8).include?("shared_human")
    end
  end
end
