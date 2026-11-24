module WorkoutsHelper
  # Tells if TrainerRoad has a workout for today.
  def workout_scheduled?(workouts)
    workouts.present? && workouts.any?
  end

  # Tells if today is a rest day, that is, a day with no workout.
  def rest_day?(workouts)
    !workout_scheduled?(workouts)
  end
end
