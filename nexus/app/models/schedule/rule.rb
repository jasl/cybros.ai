class Schedule::Rule
  include ActiveModel::Model
  include ActiveModel::Attributes

  KINDS = %w[once interval daily].freeze
  INTERVAL_SECONDS = (60..31_536_000).freeze
  # DateTime silently replaces invalid offsets and clamps leap seconds; check
  # clock/offset ranges before letting its calendar parser validate the date.
  TIMESTAMP_SHAPE = /\A\d{4}-\d\d-\d\dT(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):?[0-5]\d)\z/i
  LOCAL_TIME_SHAPE = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  MAX_TIMESTAMP_LENGTH = 40
  MAX_TIME_ZONE_LENGTH = 255
  DAILY_SEARCH_DAYS = 366

  attribute :kind, :string
  attribute :run_at, :datetime
  attribute :every_seconds, :integer
  attribute :starts_at, :datetime
  attribute :local_time, :string
  attribute :time_zone, :string

  validates :kind, inclusion: { in: KINDS }
  validates :run_at, presence: true, if: -> { kind == "once" }
  validates :starts_at, presence: true, if: -> { kind == "interval" }
  validates :every_seconds, inclusion: { in: INTERVAL_SECONDS }, if: -> { kind == "interval" }
  validates :local_time, presence: true, if: -> { kind == "daily" }
  validate :valid_time_zone, if: -> { kind == "daily" }

  def self.parse(value)
    new(value)
  end

  def initialize(attributes = {})
    attributes = attributes.to_h.transform_keys(&:to_s)
    super(kind: attributes["kind"])

    case kind
    when "once"
      self.run_at = parse_timestamp(attributes["run_at"])
    when "interval"
      self.starts_at = parse_timestamp(attributes["starts_at"])
      self.every_seconds = parse_interval(attributes["every_seconds"])
    when "daily"
      self.local_time = parse_local_time(attributes["local_time"])
      self.time_zone = attributes["time_zone"].to_s
    else
      # The inclusion validator owns unknown kinds; serialization remains safe.
    end
  end

  def to_h
    case kind
    when "once"
      { "kind" => kind, "run_at" => run_at&.iso8601(6) }
    when "interval"
      { "kind" => kind, "every_seconds" => every_seconds, "starts_at" => starts_at&.iso8601(6) }
    when "daily"
      { "kind" => kind, "local_time" => local_time, "time_zone" => time_zone }
    else
      { "kind" => kind }
    end
  end

  # Callers validate once before calculating occurrences. These methods never
  # consult a clock: the scheduler supplies its own authoritative instant.
  def next_after(time)
    occurrence(time, inclusive: false)
  end

  def first_at_or_after(time)
    occurrence(time, inclusive: true)
  end

  private

    def parse_timestamp(value)
      string = value.to_s
      return unless string.length <= MAX_TIMESTAMP_LENGTH && TIMESTAMP_SHAPE.match?(string)

      DateTime.iso8601(string).to_time.utc.floor(6)
    rescue ArgumentError
      nil
    end

    def parse_interval(value)
      string = value.to_s
      if string.length <= 8 && /\A\d+\z/.match?(string)
        Integer(string, 10)
      end
    end

    def parse_local_time(value)
      string = value.to_s
      string if string.length == 5 && LOCAL_TIME_SHAPE.match?(string)
    end

    def valid_time_zone
      if time_zone.length <= MAX_TIME_ZONE_LENGTH
        TZInfo::Timezone.get(time_zone)
      else
        errors.add(:time_zone, :invalid)
      end
    rescue TZInfo::InvalidTimezoneIdentifier
      errors.add(:time_zone, :invalid)
    end

    def occurrence(time, inclusive:)
      case kind
      when "once"
        run_at if inclusive ? run_at >= time : run_at > time
      when "interval"
        distance = (time.to_r - starts_at.to_r) / every_seconds
        ordinal = inclusive ? distance.ceil : distance.floor + 1
        starts_at + [ordinal, 0].max * every_seconds
      when "daily"
        daily_occurrence(time, inclusive:)
      else
        raise ArgumentError, "invalid scheduled job rule"
      end
    end

    def daily_occurrence(time, inclusive:)
      zone = TZInfo::Timezone.get(time_zone)
      date = zone.to_local(time).to_date
      hour, minute = local_time.split(":").map(&:to_i)

      # Advance one civil date per iteration, bounded to one year. A missing
      # clock time skips its date, including a date lost at a dateline change.
      DAILY_SEARCH_DAYS.times do
        wall_time = Time.utc(date.year, date.month, date.day, hour, minute)
        # The greatest offset is the earliest instant of a repeated clock time;
        # choosing it before comparison prevents a second execution in the fold.
        period = zone.periods_for_local(wall_time).max_by(&:observed_utc_offset)
        if period
          candidate = wall_time - period.observed_utc_offset
          return candidate if inclusive ? candidate >= time : candidate > time
        end
        date = date.next_day
      end

      raise ArgumentError, "daily rule has no occurrence within a year"
    end
end
