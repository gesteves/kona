# Applies the results of a Whoop webhook to Intervals.icu. The event type decides which date the
# code refreshes:
#
#   - workout.updated: the date of the workout, because Whoop scores a workout late and sends an
#     update for an edit to a past workout. This also writes WhoopWorkoutStrain on the activity
#     that matches, and it adds an ActivityDescriptionJob to the queue.
#   - sleep.updated: today and yesterday, because the end of the sleep is what completes the strain
#     of the previous day. This also writes WhoopSleepPerformance.
#   - recovery.updated: today, and it also writes WhoopRecovery.
#   - each other event: today.
#
# Each write is a PUT of an absolute value that you can do more than one time. Thus the Sidekiq
# retries are safe.
class WhoopWebhookProcessor
  # Goes at the start of each log line from this processor, thus you can find them with grep.
  LOG_PREFIX = "Whoop webhook:"

  def initialize(whoop: Whoop.new, intervals: Intervals.new)
    @whoop = whoop
    @intervals = intervals
  end

  # @param event_type [String] The Whoop webhook event type.
  # @param resource_id [String] The resource UUID of the event: a workout UUID for a workout.*
  #   event, and a *sleep* UUID for both a sleep.* event and a recovery.* event, as the Whoop v2
  #   specification says.
  def process(event_type, resource_id)
    case event_type
    when "workout.updated"
      process_workout_updated(resource_id)
    when "sleep.updated"
      # Get both days in one fetch. Each refresh gets its date and one day at each side, thus two
      # separate requests would read the same data two times and cover a span of 4 days.
      refresh_daily_whoop_strain(today - 1, today)
      refresh_sleep_performance(resource_id)
    when "recovery.updated"
      refresh_daily_whoop_strain(today)
      refresh_recovery(resource_id)
    else
      # TODO: workout.deleted comes here, thus a Whoop workout that a user deletes leaves an old
      # WhoopWorkoutStrain on the Intervals.icu activity. Decide the correct behavior before you
      # make a path that removes it.
      refresh_daily_whoop_strain(today)
    end
  end

  private

  def process_workout_updated(workout_id)
    workout = @whoop.get_workout(workout_id)
    if workout.nil?
      log_info("workout.updated #{workout_id} not found or not SCORED yet — skipping")
      return
    end

    # Use the day of the workout, and not today. A late score or an edit to a past workout changes
    # the strain of that day, and not the strain of today.
    workout_date = workout[:start_time].in_time_zone(timezone).to_date
    refresh_daily_whoop_strain(workout_date)

    match = matching_activity(workout, workout_date)
    return if match.nil?

    write_custom_field(:WhoopWorkoutStrain, "activity #{match[:id]}", workout[:strain]) do
      @intervals.update_activity!(match[:id], WhoopWorkoutStrain: workout[:strain])
    end

    enqueue_description(match, workout)
  end

  # Finds the Intervals.icu activity for a Whoop workout. It searches the date of the workout and
  # one day at each side, for the timezone limits and for a workout through the night.
  # @return [Hash, nil] The activity, or nil if nothing matches.
  def matching_activity(workout, workout_date)
    candidates = @intervals.activities!(oldest: workout_date - 1, newest: workout_date + 1)
    match = candidates.find { |candidate| ActivityMatcher.matches?(candidate, workout, timezone) }
    log_info("workout.updated #{workout[:id]}: no matching Intervals.icu activity on #{workout_date} — skipping") if match.nil?
    match
  end

  # Adds the description job to the queue for an activity that matches, but only for a swim, a
  # bike ride, or a run. Each other sport keeps its WhoopWorkoutStrain and gets no description. The
  # job is separate from the metric sync, on purpose: it runs again by itself, and it continues to
  # work without Whoop, with only the 🔥 line absent. Only the strain goes to the job. The
  # generator makes each other value again and does the eligibility check.
  def enqueue_description(match, workout)
    match_type = ActivityMatcher.normalize_type(match[:type])
    unless ActivityDescription::Generator::ELIGIBLE_SPORTS.include?(match_type)
      log_info("workout.updated #{workout[:id]} → activity #{match[:id]}: type=#{match_type} is not swim/bike/run — skipping auto-description")
      return
    end

    ActivityDescriptionJob.perform_async(match[:id], workout[:strain])
  end

  # Writes the raw 0–21 cycle strain of each date to its Intervals.icu wellness record. The code
  # gets the cycles one time for the full span, with one extra day at each side, and puts them in
  # groups by their end time in the timezone of the athlete. A cycle that is not complete counts as
  # today.
  # @param dates [Array<Date>] The dates to refresh.
  def refresh_daily_whoop_strain(*dates)
    return if dates.empty?

    cycles = @whoop.raw_cycles((dates.min - 1).iso8601, (dates.max + 1).iso8601)

    dates.each do |date|
      cycle = cycles.find do |candidate|
        next false unless candidate[:score_state] == "SCORED"

        cycle_date = candidate[:end].present? ? Time.iso8601(candidate[:end]).in_time_zone(timezone).to_date : today
        cycle_date == date
      end

      if cycle.nil?
        log_info("no Whoop strain data for #{date} — leaving wellness untouched")
        next
      end

      write_wellness(date, :WhoopStrain, cycle.dig(:score, :strain))
    end
  end

  # Writes the performance percentage of a sleep to the wellness record of its local end date. It
  # does nothing for a nap and for a sleep with no performance score.
  def refresh_sleep_performance(sleep_id)
    sleep_data = @whoop.get_sleep(sleep_id)
    if sleep_data.nil?
      log_info("sleep #{sleep_id} not found or not SCORED — skipping WhoopSleepPerformance")
      return
    end
    if sleep_data[:nap]
      log_info("sleep #{sleep_id} is a nap — skipping WhoopSleepPerformance")
      return
    end

    performance = sleep_data.dig(:score, :sleep_performance_percentage)
    if performance.nil?
      log_info("sleep #{sleep_id} has no sleep_performance_percentage — skipping")
      return
    end

    date = local_date_from_offset(sleep_data[:end], sleep_data[:timezone_offset])
    write_wellness(date, :WhoopSleepPerformance, performance)
  end

  # Writes the recovery score of the cycle that the sleep has a score for. The key is the local end
  # date of the sleep. A recovery.updated payload has the UUID of the sleep, not of the recovery.
  def refresh_recovery(sleep_id)
    sleep_data = @whoop.get_sleep(sleep_id)
    if sleep_data.nil?
      log_info("sleep #{sleep_id} not found or not SCORED — skipping WhoopRecovery")
      return
    end

    recovery = @whoop.get_recovery_for_cycle(sleep_data[:cycle_id])
    if recovery.nil?
      log_info("no SCORED recovery for cycle #{sleep_data[:cycle_id]} — skipping WhoopRecovery")
      return
    end

    date = local_date_from_offset(sleep_data[:end], sleep_data[:timezone_offset])
    write_wellness(date, :WhoopRecovery, recovery.dig(:score, :recovery_score))
  end

  # Writes a custom field to the wellness record of a date. It checks for a field that is absent.
  def write_wellness(date, field, value)
    write_custom_field(field, "wellness #{date}", value) do
      @intervals.update_wellness!(date.iso8601, field => value)
    end
  end

  # Does a write to a custom Intervals.icu field. A 422 means that the settings of the athlete do
  # not have that field. The code writes a warning and continues, thus one field that is absent
  # cannot stop the other results of the webhook. Each other error goes to the caller and the job
  # runs again.
  def write_custom_field(field, target, value)
    yield
    log_info("updated #{target} #{field} value=#{value}")
  rescue ApplicationService::HttpError => e
    raise unless e.status == 422

    log_warn(
      "#{target}: Intervals.icu rejected #{field} (422). " \
      "Create the custom field in Intervals.icu → Settings → Custom Fields to enable this. " \
      "Response: #{e.body.presence || '(empty)'}"
    )
  end

  # Changes a UTC timestamp into a local calendar date with the Whoop timezone_offset. That is the
  # offset at the moment of the event, and not the current offset of the athlete.
  # @return [Date]
  def local_date_from_offset(utc_timestamp, offset)
    seconds =
      case offset
      when "Z" then 0
      when /\A([+-])(\d{2}):?(\d{2})\z/ then (Regexp.last_match(1) == "-" ? -1 : 1) * (Regexp.last_match(2).to_i * 3600 + Regexp.last_match(3).to_i * 60)
      else raise ArgumentError, "Unrecognized fixed timezone offset: #{offset}"
      end

    (Time.iso8601(utc_timestamp) + seconds).utc.to_date
  end

  def timezone
    @timezone ||= @intervals.athlete_timezone
  end

  # The code keeps this value, thus one run has one "today". sleep.updated reads today and
  # yesterday, and without this the run could go through midnight.
  def today
    @today ||= Time.find_zone!(timezone).today
  end

  def log_info(message)
    Rails.logger.info("#{LOG_PREFIX} #{message}")
  end

  def log_warn(message)
    Rails.logger.warn("#{LOG_PREFIX} #{message}")
  end
end
