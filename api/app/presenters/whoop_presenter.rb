# Presents a Whoop stats payload for the widget view: the rounded scores, the labels, and the
# "Today's", "Yesterday's", or "Latest Metrics" heading. This replaces the WhoopHelper mixin, which
# read the @whoop, @workouts, and @time_zone instance variables of the controller. This presenter
# takes the same data as constructor arguments.
class WhoopPresenter
  include WorkoutsHelper # rest_day?, for the strain label

  # @param stats [Hash] The Whoop stats: { physiological_cycle:, sleep:, recovery: }.
  # @param workouts [Array, nil] The TrainerRoad workouts for today.
  # @param time_zone [String, nil] The IANA timezone id for the heading. Without it, the code uses
  #   the default from the configuration.
  def initialize(stats:, workouts: [], time_zone: nil)
    @stats = stats
    @workouts = workouts || []
    @time_zone = time_zone.presence || TimeZoneResolver.default
  end

  # The label for the metrics, from the time of the last wakeup. The markup of the heading is in the
  # view, thus you can compare it with the web placeholder that it replaces.
  # @return [String] "Today’s", "Yesterday’s", or "Latest".
  def heading_label
    wakeup_time = last_wakeup_time
    current_date = Time.current.in_time_zone(@time_zone).to_date

    return "Latest" if wakeup_time.blank?
    return "Today’s" if wakeup_time.to_date == current_date
    return "Yesterday’s" if wakeup_time.to_date == current_date - 1.day

    "Latest"
  end

  # The Whoop sleep score, rounded.
  # @return [Integer] The sleep score, rounded to the nearest integer.
  def sleep_score
    @stats.dig(:sleep, :score, :sleep_performance_percentage).round
  end

  # The Whoop recovery score, rounded.
  # @return [Integer] The recovery score, rounded to the nearest integer.
  def recovery_score
    @stats.dig(:recovery, :score, :recovery_score).round
  end

  # The Whoop strain score, with one decimal. It removes a ".0" at the end.
  # @return [String] The strain score.
  def strain_score
    rounded = @stats.dig(:physiological_cycle, :score, :strain).round(1)
    rounded % 1 == 0 ? rounded.to_i.to_s : rounded.to_s
  end

  # The label for the current strain level.
  # @return [String] The strain label: Light, Moderate, High, All Out, or another one.
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
    else
      "All Out"
    end
  end

  # The label for the current sleep score.
  # @return [String] The sleep label: Poor, Sufficient, or Optimal.
  def sleep_label
    score = sleep_score
    return "None" if score.blank? || score.zero?

    case score
    when 0..69
      "Poor"
    when 70..84
      "Sufficient"
    else
      "Optimal"
    end
  end

  # The label for the current recovery score.
  # @return [String] The recovery label: Poor, Adequate, or Sufficient.
  def recovery_label
    recovery = recovery_score
    return "None" if recovery.blank? || recovery.zero?
    return "Nice." if recovery == 69

    case recovery
    when 0..33
      "Poor"
    when 34..66
      "Adequate"
    else
      "Sufficient"
    end
  end

  # The Font Awesome icon for the current recovery level.
  # @return [String] The name of the icon: skull for a low recovery, and person-meditating for each
  #   other level.
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

  # The Whoop referral link for the footer of the widget, or nil if there is no configuration, and
  # the view then omits the footer. The code reads it here, thus the view does not read ENV.
  # @return [String, nil]
  def referral_url
    ENV["WHOOP_REFERRAL_URL"].presence
  end

  private

  # The time of the last wakeup, that is, the end of the last sleep.
  # @return [ActiveSupport::TimeWithZone, nil] The wakeup time.
  def last_wakeup_time
    return if @stats.dig(:sleep, :end).blank?
    DateTime.parse(@stats.dig(:sleep, :end)).in_time_zone(@time_zone)
  end
end
