# Applies Whoop webhook side effects to Intervals.icu. Which date's wellness is refreshed
# depends on the event type:
#
#   - workout.updated: the workout's own date, since Whoop scores workouts late and fires
#     updates for retroactive edits. Also writes WhoopWorkoutStrain on the matching activity
#     and enqueues an ActivityDescriptionJob.
#   - sleep.updated: today and yesterday — sleep finalization is what marks the prior day's
#     strain complete — plus WhoopSleepPerformance.
#   - recovery.updated: today, plus WhoopRecovery.
#   - anything else: today.
#
# Every write is an idempotent PUT of an absolute value, so Sidekiq's retries are safe.
class WhoopWebhookProcessor
  # Prefixes every log line this processor emits, for greppability.
  LOG_PREFIX = "Whoop webhook:"

  def initialize(whoop: Whoop.new, intervals: Intervals.new)
    @whoop = whoop
    @intervals = intervals
  end

  # @param event_type [String] The Whoop webhook event type.
  # @param resource_id [String] The event's resource UUID: a workout UUID for workout.*
  #   events, a *sleep* UUID for both sleep.* and recovery.* events, per Whoop's v2 spec.
  def process(event_type, resource_id)
    case event_type
    when "workout.updated"
      process_workout_updated(resource_id)
    when "sleep.updated"
      # Both days in one fetch: each refresh pulls its date ±1, so asking separately means two
      # overlapping paginated requests covering a 4-day span between them.
      refresh_daily_whoop_strain(today - 1, today)
      refresh_sleep_performance(resource_id)
    when "recovery.updated"
      refresh_daily_whoop_strain(today)
      refresh_recovery(resource_id)
    else
      # TODO: workout.deleted falls through here, so a deleted Whoop workout leaves an orphan
      # WhoopWorkoutStrain on the Intervals.icu activity. Decide the intended semantics
      # before wiring up a cleanup path.
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

    # The workout's day, not today: a late score or a retroactive edit changes that day's
    # strain, not the current day's.
    workout_date = workout[:start_time].in_time_zone(timezone).to_date
    refresh_daily_whoop_strain(workout_date)

    match = matching_activity(workout, workout_date)
    return if match.nil?

    write_custom_field(:WhoopWorkoutStrain, "activity #{match[:id]}", workout[:strain]) do
      @intervals.update_activity!(match[:id], WhoopWorkoutStrain: workout[:strain])
    end

    enqueue_description(match, workout)
  end

  # Finds the Intervals.icu activity matching a Whoop workout, searching its date ± a day to
  # absorb timezone boundaries and overnight workouts.
  # @return [Hash, nil] The activity, or nil when nothing matches.
  def matching_activity(workout, workout_date)
    candidates = @intervals.activities!(oldest: workout_date - 1, newest: workout_date + 1)
    match = candidates.find { |candidate| ActivityMatcher.matches?(candidate, workout, timezone) }
    log_info("workout.updated #{workout[:id]}: no matching Intervals.icu activity on #{workout_date} — skipping") if match.nil?
    match
  end

  # Enqueues the description job for a matched activity, but only for swim, bike, and run —
  # other sports keep their WhoopWorkoutStrain and simply get no description. The job is
  # deliberately decoupled from the metric sync: it retries independently, and it keeps
  # working without Whoop, losing only the 🔥 line. Only the strain is passed through; the
  # generator re-derives everything else and owns the eligibility check.
  def enqueue_description(match, workout)
    match_type = ActivityMatcher.normalize_type(match[:type])
    unless ActivityDescription::Generator::ELIGIBLE_SPORTS.include?(match_type)
      log_info("workout.updated #{workout[:id]} → activity #{match[:id]}: type=#{match_type} is not swim/bike/run — skipping auto-description")
      return
    end

    ActivityDescriptionJob.perform_async(match[:id], workout[:strain])
  end

  # Writes each date's raw 0–21 cycle strain to its Intervals.icu wellness record. Cycles are
  # fetched once for the whole span with a ±1-day buffer and bucketed by their end time in the
  # athlete's timezone; an in-progress cycle counts as today.
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

  # Writes a sleep's performance percentage to the wellness record for its local end date.
  # Skips naps and sleeps with no performance score.
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

  # Writes the recovery score for the cycle a sleep was scored against, keyed by the sleep's
  # local end date. recovery.updated payloads carry the sleep's UUID, not the recovery's.
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

  # Writes a custom field to the wellness record for a date, guarded against a missing field.
  def write_wellness(date, field, value)
    write_custom_field(field, "wellness #{date}", value) do
      @intervals.update_wellness!(date.iso8601, field => value)
    end
  end

  # Runs a write targeting a custom Intervals.icu field. A 422 means the field hasn't been
  # created in the athlete's settings; that's warned and swallowed, so one missing field can't
  # poison the rest of the webhook's side effects. Anything else propagates and retries.
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

  # Converts a UTC timestamp to a local calendar date using Whoop's fixed timezone_offset —
  # the offset in force at the moment of the event, not the athlete's current one.
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

  # Memoized so one run has a single consistent "today" — sleep.updated reads both today and
  # yesterday, and could otherwise straddle midnight mid-run.
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
