require 'active_support/all'

module WhoopHelpers
  def show_whoop?
    data.whoop.sleep_score.present? && data.whoop.recovery_score.present? && data.whoop.strain.present?
  end

  def whoop_sleep_score
    return "0" if data.whoop.sleep_score.blank?
    data.whoop.sleep_score.round
  end

  def whoop_recovery_score
    return "0" if data.whoop.recovery_score.blank?
    data.whoop.recovery_score.round
  end

  def whoop_strain_score
    data.whoop.strain.round(1).to_s
  end

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
end
