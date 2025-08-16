require 'active_support/all'

module WhoopHelpers
  # Returns whether Whoop data should be displayed.
  # @return [Boolean] True if all required Whoop metrics are present.
  def show_whoop?
    data.whoop.sleep_score.present? && data.whoop.recovery_score.present? && data.whoop.strain.present?
  end

  # Returns the rounded Whoop sleep score.
  # @return [String] The sleep score rounded to the nearest integer.
  def whoop_sleep_score
    data.whoop.sleep_score.round
  end

  # Returns the rounded Whoop recovery score.
  # @return [String] The recovery score rounded to the nearest integer.
  def whoop_recovery_score
    data.whoop.recovery_score.round
  end

  # Returns the Whoop strain score formatted to one decimal place.
  # @return [String] The strain score as a string with one decimal place.
  def whoop_strain_score
    data.whoop.strain.round(1).to_s
  end

  # Returns the descriptive label for the current strain level.
  # @return [String] The strain label (Light, Moderate, High, All Out) or empty string if not available.
  def whoop_strain_label
    strain = data.whoop.strain
    return "" if strain.blank?
    
    case strain
    when 0..9.9
      "Light"
    when 10..13.9
      "Moderate"
    when 14..17.9
      "High"
    when 18..21
      "All Out"
    else
      "—"
    end
  end

  # Returns the descriptive label for the current sleep score.
  # @return [String] The sleep label (Poor, Sufficient, Optimal) or empty string if not available.
  def whoop_sleep_label
    sleep_score = data.whoop.sleep_score
    return "" if sleep_score.blank?
    
    case sleep_score
    when 0..69
      "Poor"
    when 70..84
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
    recovery = data.whoop.recovery_score
    return "" if recovery.blank?
    
    case recovery
    when 0..33
      "Low"
    when 34..66
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
    recovery = data.whoop.recovery_score
    return "person-meditating" if recovery.blank?
    
    case recovery
    when 0..33
      "skull"
    else
      "person-meditating"
    end
  end
end
