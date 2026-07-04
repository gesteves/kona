module WorkoutsHelper
  # Checks if there are any workouts scheduled in TrainerRoad today.
  # @return [Boolean] true if there are scheduled workouts, otherwise false.
  def workout_scheduled?
    @workouts.present? && @workouts.any?
  end

  # Determines if today is a rest day (no workouts scheduled).
  # @return [Boolean] true if it is a rest day, otherwise false.
  def rest_day?
    !workout_scheduled?
  end
end
