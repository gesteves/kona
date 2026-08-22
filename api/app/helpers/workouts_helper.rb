module WorkoutsHelper
  # Tells if TrainerRoad has a workout for today.
  # @param workouts [Array, nil] The workouts for today.
  # @return [Boolean] True if there is a workout, and false if there is none.
  def workout_scheduled?(workouts)
    workouts.present? && workouts.any?
  end

  # Tells if today is a rest day, that is, a day with no workout.
  # @param workouts [Array, nil] The workouts for today.
  # @return [Boolean] True if it is a rest day, and false if it is not.
  def rest_day?(workouts)
    !workout_scheduled?(workouts)
  end
end
