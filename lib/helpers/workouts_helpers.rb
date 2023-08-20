module WorkoutsHelpers
  def is_rest_day?
    data.trainerroad.workouts.blank?
  end
end
