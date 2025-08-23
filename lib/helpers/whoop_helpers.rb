require 'active_support/all'

module WhoopHelpers
  # Returns whether Whoop data should be displayed.
  # @return [Boolean] True if all required Whoop metrics are present.
  def show_whoop?
    data.whoop.physiological_cycle.present? && data.whoop.sleep.present? && data.whoop.recovery.present?
  end

  # Returns the heading for the Whoop section.
  # @return [String] The heading for the Whoop section.
  def whoop_heading
    wakeup_time = whoop_last_wakeup_time
    current_date = current_time.in_time_zone(location_time_zone).to_date
    
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

  # Returns the time I last woke up, i.e. the end of the last sleep.
  # @return [DateTime] The wakeup time.
  def whoop_last_wakeup_time
    return if data.whoop.sleep.end.blank?
    DateTime.parse(data.whoop.sleep.end).in_time_zone(location_time_zone)
  end

  # Returns the rounded Whoop sleep score.
  # @return [String] The sleep score rounded to the nearest integer.
  def whoop_sleep_score
    data.whoop.sleep.score.sleep_performance_percentage.round
  end

  # Returns the rounded Whoop recovery score.
  # @return [String] The recovery score rounded to the nearest integer.
  def whoop_recovery_score
    data.whoop.recovery.score.recovery_score.round
  end

  # Returns the Whoop strain score formatted to one decimal place, omitting .0.
  # @return [String] The strain score as a string with one decimal place, or no decimal if .0.
  def whoop_strain_score
    rounded = data.whoop.physiological_cycle.score.strain.round(1)
    rounded % 1 == 0 ? rounded.to_i.to_s : rounded.to_s
  end

  # Returns the descriptive label for the current strain level.
  # @return [String] The strain label (Light, Moderate, Strenuous, All Out, etc.)
  def whoop_strain_label
    strain = data.whoop.physiological_cycle.score.strain
    return "Nothing" if strain.blank? || strain.zero?
    
    case strain
    when 0...10
      is_rest_day? ? "Rest Day" : "Light"
    when 10...14
      "Moderate"
    when 14...18
      "Strenuous"
    when 18..21
      "All Out"
    end
  end

  # Returns the descriptive label for the current sleep score.
  # @return [String] The sleep label (Poor, Sufficient, Optimal, etc.)
  def whoop_sleep_label
    sleep_score = whoop_sleep_score
    return "None" if sleep_score.blank? || sleep_score.zero?
    
    case sleep_score
    when 0...70
      "Poor"
    when 70...85
      "Sufficient"
    when 85..100
      "Optimal"
    end
  end

  # Returns the descriptive label for the current recovery score.
  # @return [String] The recovery label (Low, Adequate, Sufficient, etc.)
  def whoop_recovery_label
    recovery = whoop_recovery_score
    return "Zilch" if recovery.blank? || recovery.zero?
    return "Nice." if recovery == 69
    
    case recovery
    when 0...11
      "Basically Dead"
    when 11...34
      "Poor"
    when 34...67
      "Adequate"
    when 67...90
      "Sufficient"
    when 90...100
      "Excellent"
    end
  end

  # Returns the appropriate Font Awesome icon for the current recovery level.
  # @return [String] The icon name (skull for low recovery, person-meditating otherwise).
  def whoop_recovery_icon
    recovery = whoop_recovery_score
    return "person-meditating" if recovery.blank?
    
    case recovery
    when 0..33
      "skull"
    else
      "person-meditating"
    end
  end
end
