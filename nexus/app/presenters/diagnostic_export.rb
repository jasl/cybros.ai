require "zlib"

# Each-only Rack body. Projection finishes and returns its database connection
# before yielding bytes; failed reads or disconnects cannot publish an end record.
class DiagnosticExport
  PAGE_SIZE = 100
  CONSISTENCY = "observation_interval".freeze

  def each
    compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16)
    counts = Hash.new(0)
    records do |record|
      counts[record.fetch(:type)] += 1
      write_record(compressor, record) { |chunk| yield chunk }
    end
    completion = envelope("end", completed_at: Time.current.iso8601, counts: counts.merge("end" => 1))
    write_record(compressor, completion) { |chunk| yield chunk }
    compressor.finish { |chunk| yield chunk }
  ensure
    compressor&.close
  end

  # Nothing is acquired until #each, whose ensure owns every exit.
  def close
  end

  private

    def write_record(compressor, record)
      compressor.deflate("#{ActiveSupport::JSON.encode(record)}\n", Zlib::SYNC_FLUSH) { |chunk| yield chunk }
      # Block-mode deflate retains its final short chunk after SYNC_FLUSH.
      tail = compressor.flush_next_out
      yield tail unless tail.empty?
    end

    def read(&block)
      ApplicationRecord.uncached do
        ApplicationRecord.connection_pool.with_connection(prevent_permanent_checkout: true, &block)
      end
    end
end
