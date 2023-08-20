module WorkoutsHelpers
  def is_workout_scheduled?
    data.trainerroad.workouts.present?
  end
end
