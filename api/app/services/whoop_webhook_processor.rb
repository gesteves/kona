# Applies Whoop webhook side effects to Intervals.icu, mirroring domestique's
# dispatchWhoopWebhook. The wellness-refresh date depends on the event type:
#
#   - workout.updated: refresh the *workout's* date (Whoop sometimes scores workouts late
#     or fires updates for retroactive edits, so the event's date isn't necessarily today).
#     Also writes WhoopWorkoutStrain on the matching Intervals.icu activity and enqueues an
#     ActivityDescriptionJob to (re)generate the activity's description (a separate,
#     source-agnostic, independently-retried concern).
#   - sleep.updated: refresh today and yesterday (sleep finalization is what marks the
#     prior day's strain complete on Whoop), plus WhoopSleepPerformance.
#   - recovery.updated: refresh today, plus WhoopRecovery.
#   - All other event types: refresh today's wellness.
#
# All writes are idempotent PUTs of absolute values, so the job's Sidekiq retries are safe.
class WhoopWebhookProcessor
  # Prefix shared by every log line this processor emits, for greppability.
  LOG_PREFIX = "Whoop webhook:"

  def initialize(whoop: Whoop.new, intervals: Intervals.new)
    @whoop = whoop
    @intervals = intervals
  end

  # @param event_type [String] The Whoop webhook event type (e.g. "workout.updated").
  # @param resource_id [String] The event's resource UUID — a workout UUID for workout.*
  #   events, a *sleep* UUID for sleep.* and recovery.* events (per Whoop's v2 spec).
  def process(event_type, resource_id)
    case event_type
    when "workout.updated"
      process_workout_updated(resource_id)
    when "sleep.updated"
      refresh_daily_whoop_strain(today)
      refresh_daily_whoop_strain(today - 1)
      refresh_sleep_performance(resource_id)
    when "recovery.updated"
      refresh_daily_whoop_strain(today)
      refresh_recovery(resource_id)
    else
      # TODO: workout.deleted falls through here, so it refreshes today's wellness but does
      # not clear WhoopWorkoutStrain on the matched activity — a deleted Whoop workout
      # leaves an orphan strain value on the ICU side. Carried over from domestique; decide
      # on intended semantics before wiring up the cleanup path.
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

    # Refresh wellness for the workout's day (not today): a workout scored late, or a
    # retroactive edit to a past workout, changes that day's strain — not the current day's.
    workout_date = workout[:start_time].in_time_zone(timezone).to_date
    refresh_daily_whoop_strain(workout_date)

    match = matching_activity(workout, workout_date)
    return if match.nil?

    write_custom_field(:WhoopWorkoutStrain, "activity #{match[:id]}", workout[:strain]) do
      @intervals.update_activity!(match[:id], WhoopWorkoutStrain: workout[:strain])
    end

    enqueue_description(match, workout)
  end

  # Finds the Intervals.icu activity that matches the Whoop workout, searching the workout's
  # date ± a 1-day buffer (which absorbs timezone boundaries and overnight workouts).
  # @return [Hash, nil] The matching activity, or nil (logged) when nothing matches.
  def matching_activity(workout, workout_date)
    candidates = @intervals.activities!(oldest: workout_date - 1, newest: workout_date + 1)
    match = candidates.find { |candidate| ActivityMatcher.matches?(candidate, workout, timezone) }
    log_info("workout.updated #{workout[:id]}: no matching Intervals.icu activity on #{workout_date} — skipping") if match.nil?
    match
  end

  # Enqueues the (source-agnostic) description job for a matched activity, but only for
  # swim/bike/run. Other sports keep the WhoopWorkoutStrain written above; they just don't
  # get a description. The job runs decoupled from the Whoop metric sync — it retries
  # independently, and if the Whoop integration ever goes away the description keeps working
  # (triggered elsewhere) minus the 🔥 line. Only the Whoop strain is passed through; the
  # generator re-derives everything else from Intervals.icu. Eligibility is owned by the
  # generator (which re-checks it), so we defer to its constant.
  def enqueue_description(match, workout)
    match_type = ActivityMatcher.normalize_type(match[:type])
    unless ActivityDescription::Generator::ELIGIBLE_SPORTS.include?(match_type)
      log_info("workout.updated #{workout[:id]} → activity #{match[:id]}: type=#{match_type} is not swim/bike/run — skipping auto-description")
      return
    end

    ActivityDescriptionJob.perform_async(match[:id], workout[:strain])
  end

  # Writes the day's Whoop strain (the raw 0–21 cycle strain) to the Intervals.icu wellness
  # record for that date. Cycles are fetched with a ±1-day buffer and bucketed by their end
  # time in the athlete's timezone; an in-progress cycle (no end yet) counts as today.
  # @param date [Date]
  def refresh_daily_whoop_strain(date)
    cycles = @whoop.raw_cycles((date - 1).iso8601, (date + 1).iso8601)
    cycle = cycles.find do |candidate|
      next false unless candidate[:score_state] == "SCORED"

      cycle_date = candidate[:end].present? ? Time.iso8601(candidate[:end]).in_time_zone(timezone).to_date : today
      cycle_date == date
    end

    if cycle.nil?
      log_info("no Whoop strain data for #{date} — leaving wellness untouched")
      return
    end

    write_wellness(date, :WhoopStrain, cycle.dig(:score, :strain))
  end

  # Writes a sleep's performance percentage to the wellness record for the sleep's local
  # end date. Skips naps and sleeps without a performance score.
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

  # Writes the recovery score for the cycle the given sleep was scored against, keyed by
  # the sleep's local end date. (recovery.updated payloads carry the *sleep* UUID.)
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

  # Runs a write that targets a custom Intervals.icu field. If the field hasn't been created
  # in the athlete's settings, Intervals.icu responds 422; that's logged as a clear warning
  # and swallowed so a missing custom field can't poison the rest of the webhook's side
  # effects. Any other error propagates (the job's writes are idempotent, so retries are safe).
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

  # Converts a UTC timestamp into the local calendar date using a fixed offset like Whoop's
  # timezone_offset ("Z", "-05:00", "+0200") — the offset that applied at the moment of the
  # event, regardless of the athlete's current timezone.
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

  # Memoized so a single run has one consistent "today" — otherwise sleep.updated, which
  # reads both today and today - 1, could straddle midnight mid-run.
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
