module WorkoutsHelper
  # Checks if there are any workouts scheduled in TrainerRoad today.
  # @param workouts [Array, nil] Today's scheduled workouts.
  # @return [Boolean] true if there are scheduled workouts, otherwise false.
  def workout_scheduled?(workouts)
    workouts.present? && workouts.any?
  end

  # Determines if today is a rest day (no workouts scheduled).
  # @param workouts [Array, nil] Today's scheduled workouts.
  # @return [Boolean] true if it is a rest day, otherwise false.
  def rest_day?(workouts)
    !workout_scheduled?(workouts)
  end
end
