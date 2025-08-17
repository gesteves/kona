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
    label = if whoop_cycle_start.present? && whoop_cycle_end.blank?
      "Today’s"
    elsif whoop_cycle_end&.to_date == current_time.in_time_zone(location_time_zone).to_date - 1.day
      "Yesterday’s"
    else
      "Latest"
    end
    "#{label} Metrics <i>from</i> Whoop"
  end

  # Returns the start time of the Whoop cycle.
  # @return [DateTime] The start time of the Whoop cycle.
  def whoop_cycle_start
    DateTime.parse(data.whoop.physiological_cycle.start).in_time_zone(location_time_zone)
  end

  # Returns the end time of the Whoop cycle.
  # @return [DateTime] The end time of the Whoop cycle.
  def whoop_cycle_end
    return if data.whoop.physiological_cycle.end.blank?
    DateTime.parse(data.whoop.physiological_cycle.end).in_time_zone(location_time_zone)
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
  # @return [String] The strain label (Light, Moderate, Strenuous, All Out) or empty string if not available.
  def whoop_strain_label
    strain = data.whoop.physiological_cycle.score.strain
    return "" if strain.blank?
    
    case strain
    when 0...10
      "Light"
    when 10...14
      "Moderate"
    when 14...18
      "Strenuous"
    when 18..21
      "All Out"
    else
      ""
    end
  end

  # Returns the descriptive label for the current sleep score.
  # @return [String] The sleep label (Poor, Sufficient, Optimal) or empty string if not available.
  def whoop_sleep_label
    sleep_score = data.whoop.sleep.score.sleep_performance_percentage
    return "" if sleep_score.blank?
    
    case sleep_score
    when 0...70
      "Poor"
    when 70...85
      "Sufficient"
    when 85..100
      "Optimal"
    else
      ""
    end
  end

  # Returns the descriptive label for the current recovery score.
  # @return [String] The recovery label (Low, Adequate, Sufficient) or empty string if not available.
  def whoop_recovery_label
    recovery = data.whoop.recovery.score.recovery_score
    return "" if recovery.blank?
    
    case recovery
    when 0...34
      "Low"
    when 34...67
      "Adequate"
    when 67..100
      "Sufficient"
    else
      ""
    end
  end

  # Returns the appropriate Font Awesome icon for the current recovery level.
  # @return [String] The icon name (skull for low recovery, person-meditating otherwise).
  def whoop_recovery_icon
    recovery = data.whoop.recovery.score.recovery_score
    return "person-meditating" if recovery.blank?
    
    case recovery
    when 0..33
      "skull"
    else
      "person-meditating"
    end
  end
end
