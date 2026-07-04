# Presents a Whoop stats payload for the widget view: rounded scores, descriptive labels,
# and the "Today's/Yesterday's/Latest Metrics" heading. Replaces the old WhoopHelper mixin,
# which read the controller's @whoop/@workouts/@time_zone ivars implicitly — the presenter
# takes the same data as explicit constructor arguments.
class WhoopPresenter
  include WorkoutsHelper # rest_day?, for the strain label

  # @param stats [Hash] The Whoop stats ({ physiological_cycle:, sleep:, recovery: }).
  # @param workouts [Array, nil] Today's scheduled TrainerRoad workouts.
  # @param time_zone [String, nil] IANA timezone id for the relative heading; falls back to
  #   the configured default.
  def initialize(stats:, workouts: [], time_zone: nil)
    @stats = stats
    @workouts = workouts || []
    @time_zone = time_zone.presence || TimeZoneResolver.default
  end

  # The heading for the Whoop section, labeled relative to the last wakeup.
  # @return [String] The heading HTML.
  def heading
    wakeup_time = last_wakeup_time
    current_date = Time.current.in_time_zone(@time_zone).to_date

    label = if wakeup_time.blank?
      "Latest"
    elsif wakeup_time.to_date == current_date
      "Today’s"
    elsif wakeup_time.to_date == current_date - 1.day
      "Yesterday’s"
    else
      "Latest"
    end

    "#{label} Metrics <i>from</i> <a href='https://www.whoop.com' target='_blank' rel='nofollow noopener'>Whoop</a>"
  end

  # The rounded Whoop sleep score.
  # @return [Integer] The sleep score rounded to the nearest integer.
  def sleep_score
    @stats.dig(:sleep, :score, :sleep_performance_percentage).round
  end

  # The rounded Whoop recovery score.
  # @return [Integer] The recovery score rounded to the nearest integer.
  def recovery_score
    @stats.dig(:recovery, :score, :recovery_score).round
  end

  # The Whoop strain score formatted to one decimal place, omitting .0.
  # @return [String] The strain score.
  def strain_score
    rounded = @stats.dig(:physiological_cycle, :score, :strain).round(1)
    rounded % 1 == 0 ? rounded.to_i.to_s : rounded.to_s
  end

  # The descriptive label for the current strain level.
  # @return [String] The strain label (Light, Moderate, High, All Out, etc.)
  def strain_label
    strain = @stats.dig(:physiological_cycle, :score, :strain)
    return "Nothing" if strain.blank? || strain.zero?

    case strain
    when 0...10
      rest_day?(@workouts) ? "Rest Day" : "Light"
    when 10...14
      "Moderate"
    when 14...18
      "High"
    when 18..21
      "All Out"
    end
  end

  # The descriptive label for the current sleep score.
  # @return [String] The sleep label (Poor, Sufficient, Optimal.)
  def sleep_label
    score = sleep_score
    return "None" if score.blank? || score.zero?

    case score
    when 0..69
      "Poor"
    when 70..84
      "Sufficient"
    when 85..100
      "Optimal"
    end
  end

  # The descriptive label for the current recovery score.
  # @return [String] The recovery label (Poor, Adequate, Sufficient.)
  def recovery_label
    recovery = recovery_score
    return "None" if recovery.blank? || recovery.zero?
    return "Nice." if recovery == 69

    case recovery
    when 0..33
      "Poor"
    when 34..66
      "Adequate"
    when 67..100
      "Sufficient"
    end
  end

  # The appropriate Font Awesome icon for the current recovery level.
  # @return [String] The icon name (skull for low recovery, person-meditating otherwise).
  def recovery_icon
    recovery = recovery_score
    return "person-meditating" if recovery.blank?

    case recovery
    when 0..33
      "skull"
    else
      "person-meditating"
    end
  end

  # The Whoop referral link for the widget's footer, or nil when not configured (the view
  # omits the footer). Read here so the view doesn't touch ENV.
  # @return [String, nil]
  def referral_url
    ENV["WHOOP_REFERRAL_URL"].presence
  end

  private

  # The time I last woke up, i.e. the end of the last sleep.
  # @return [ActiveSupport::TimeWithZone, nil] The wakeup time.
  def last_wakeup_time
    return if @stats.dig(:sleep, :end).blank?
    DateTime.parse(@stats.dig(:sleep, :end)).in_time_zone(@time_zone)
  end
end
