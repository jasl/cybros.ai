module CybrosAgent
  module ModelAdaptations
    # THE LOADER: `presets.yml` and `rows/*.yml` under `dir` as GEM rows,
    # then `extra:` — row files, or directories of them — as LOCAL rows. A
    # local row of a gem row's id replaces it; an entry appears once per
    # row and once across the rows of one source, a repeat a load error —
    # on two rows, the one shape that could tie (different overlapping
    # entries resolve by specificity, `Pack#for`). A pack
    # without a `default` row is refused: every reference no row covers
    # must resolve somewhere.
    class Loader
      attr_reader :dir, :extra

      def initialize(dir, extra: [])
        @dir = dir
        @extra = Array(extra)
      end

      def pack
        presets = PresetsFile.read(File.join(dir, "presets.yml"))
        gem_rows = load_rows(Dir[File.join(dir, "rows", "*.yml")].sort, presets: presets, source: "gem")
        local_rows = load_rows(local_paths, presets: presets, source: "local")
        replaced = local_rows.map(&:id)
        rows = local_rows + gem_rows.reject { |row| replaced.include?(row.id) }
        raise Invalid.new(File.join(dir, "rows"), DEFAULT_ROW, "no default row; every reference no row covers needs one") unless
          rows.any? { |row| row.id == DEFAULT_ROW }

        Pack.new(presets: presets, rows: rows, gem_ids: gem_rows.map(&:id))
      end

      private

        def local_paths
          extra.flat_map do |path|
            File.directory?(path) ? Dir[File.join(path, "*.yml")].sort : [path]
          end
        end

        def load_rows(paths, presets:, source:)
          rows = paths.map { |path| RowFile.read(path, presets: presets, source: source) }
          seen = {}
          rows.each do |row|
            row.models.each do |entry|
              raise Invalid.new(path_of(paths, row), "models", "#{entry.inspect} is also on row #{seen[entry].inspect}") if
                seen.key?(entry)

              seen[entry] = row.id
            end
          end
          rows
        end

        def path_of(paths, row)
          paths.find { |path| File.basename(path, ".yml") == row.id } || row.id
        end
    end
  end
end
