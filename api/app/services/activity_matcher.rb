# Matches an Intervals.icu activity to a Whoop workout, by the start time and the standard activity
# type. This is the same as the activity-matcher of domestique: a good match needs start times in
# the same 5 minutes, after the code removes the seconds, AND two types that agree. These are
# functions with no I/O.
module ActivityMatcher
  # Changes each raw activity type string into a standard type. The raw strings are the
  # Intervals.icu types and the Whoop sport names, in lowercase, with a space in place of each
  # underscore and hyphen. A string that is not here becomes "Other".
  ACTIVITY_TYPE_MAP = {
    # The Intervals.icu types
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
    # The other names that only Whoop uses
    "spin" => "Cycling",
    "functional fitness" => "Strength",
    "hiit" => "Strength",
    "cross country skiing" => "Skiing",
    "downhill skiing" => "Skiing"
  }.freeze

  # The maximum difference of the two start times for a match, in minutes with no seconds. A
  # difference of 5:59 gives a match, because it is 5 full minutes. A difference of 6:00 does
  # not.
  MAX_START_DIFF_MINUTES = 5

  module_function

  # Changes a raw activity type string into one of the shared type names.
  # @param type [String, nil]
  # @return [String] The standard type, or "Other".
  def normalize_type(type)
    return "Other" if type.blank?

    ACTIVITY_TYPE_MAP[type.to_s.downcase.gsub(/[_-]/, " ").strip] || "Other"
  end

  # Tells if two standard types can match: they are the same, or one of them is "Other", which
  # matches each type.
  def compatible_types?(type_a, type_b)
    type_a == type_b || type_a == "Other" || type_b == "Other"
  end

  # Tells if a raw Intervals.icu activity matches a Whoop workout in the standard shape. The two
  # start times must be in MAX_START_DIFF_MINUTES, with no seconds, and the two types must agree. An
  # import from Strava only, which domestique gave no type, never matches.
  # @param icu_activity [Hash] The raw Intervals.icu activity, with symbol keys.
  # @param whoop_workout [Hash] The Whoop workout in the standard shape:
  #   ({activity_type:, start_time:, …}).
  # @param timezone [String] The IANA timezone of the athlete, to read start_date_local.
  def matches?(icu_activity, whoop_workout, timezone)
    return false if strava_only?(icu_activity)
    return false if icu_activity[:start_date_local].blank?

    # A zone that Rails does not know, or a date that it cannot parse, is no match and no error.
    zone = Time.find_zone(timezone)
    icu_start = zone&.parse(icu_activity[:start_date_local])
    return false if icu_start.nil? || whoop_workout[:start_time].nil?

    minutes_apart = ((icu_start - whoop_workout[:start_time]).abs / 60).to_i

    minutes_apart <= MAX_START_DIFF_MINUTES &&
      compatible_types?(normalize_type(icu_activity[:type]), whoop_workout[:activity_type])
  end

  # The Intervals.icu API cannot give an import from Strava only, because of the API terms of
  # Strava. domestique marked such an import as not available and did not use it in a match.
  def strava_only?(icu_activity)
    icu_activity[:source] == "STRAVA" && icu_activity.key?(:_note)
  end
end
