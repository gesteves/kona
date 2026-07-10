# Matches Intervals.icu activities to Whoop workouts by start time + normalized activity
# type, mirroring domestique's activity-matcher: a high-confidence match requires start
# times within 5 (truncated) minutes AND compatible types. Pure functions — no I/O.
module ActivityMatcher
  # Maps raw activity type strings (Intervals.icu types and Whoop sport names, lowercased
  # with _- collapsed to spaces) to normalized types. Anything unmapped is "Other".
  ACTIVITY_TYPE_MAP = {
    # Intervals.icu types
    "ride" => "Cycling",
    "cycling" => "Cycling",
    "virtualride" => "Cycling",
    "run" => "Running",
    "running" => "Running",
    "virtualrun" => "Running",
    "swim" => "Swimming",
    "swimming" => "Swimming",
    "openwaterswim" => "Swimming",
    "alpineski" => "Skiing",
    "alpine skiing" => "Skiing",
    "backcountryski" => "Skiing",
    "nordicski" => "Skiing",
    "skiing" => "Skiing",
    "hike" => "Hiking",
    "hiking" => "Hiking",
    "rowing" => "Rowing",
    "row" => "Rowing",
    "weighttraining" => "Strength",
    "strength" => "Strength",
    "workout" => "Strength",
    # Additional Whoop-specific names
    "spin" => "Cycling",
    "functional fitness" => "Strength",
    "hiit" => "Strength",
    "cross country skiing" => "Skiing",
    "downhill skiing" => "Skiing"
  }.freeze

  # Maximum start-time difference for a match, in truncated minutes — a 5:59 gap still
  # matches (5 whole minutes), a 6:00 gap doesn't.
  MAX_START_DIFF_MINUTES = 5

  module_function

  # Normalizes a raw activity type string to one of the shared type names.
  # @param type [String, nil]
  # @return [String] The normalized type, or "Other".
  def normalize_type(type)
    return "Other" if type.blank?

    ACTIVITY_TYPE_MAP[type.to_s.downcase.gsub(/[_-]/, " ").strip] || "Other"
  end

  # Whether two normalized types can be matched: exact match, or either is "Other"
  # (which matches anything).
  def compatible_types?(type_a, type_b)
    type_a == type_b || type_a == "Other" || type_b == "Other"
  end

  # Whether a raw Intervals.icu activity matches a normalized Whoop workout: start times
  # within MAX_START_DIFF_MINUTES (truncated) and compatible types. Strava-only imports
  # (which domestique normalized without a type) never match.
  # @param icu_activity [Hash] Raw Intervals.icu activity (symbolized keys).
  # @param whoop_workout [Hash] Normalized Whoop workout ({activity_type:, start_time:, …}).
  # @param timezone [String] The athlete's IANA timezone, used to interpret start_date_local.
  def matches?(icu_activity, whoop_workout, timezone)
    return false if strava_only?(icu_activity)
    return false if icu_activity[:start_date_local].blank?

    icu_start = Time.find_zone!(timezone).parse(icu_activity[:start_date_local])
    minutes_apart = ((icu_start - whoop_workout[:start_time]).abs / 60).to_i

    minutes_apart <= MAX_START_DIFF_MINUTES &&
      compatible_types?(normalize_type(icu_activity[:type]), whoop_workout[:activity_type])
  end

  # Strava-only imports can't be fetched from the Intervals.icu API (Strava's API terms);
  # domestique marked them unavailable and excluded them from matching.
  def strava_only?(icu_activity)
    icu_activity[:source] == "STRAVA" && icu_activity.key?(:_note)
  end
end
