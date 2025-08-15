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
end
