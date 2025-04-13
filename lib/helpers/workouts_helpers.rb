module WorkoutsHelpers
  # Checks if there are any workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are scheduled workouts, otherwise false.
  def is_workout_scheduled?
    data.trainerroad.workouts.any? || data.runna.workouts.any?
  end

  # Determines if the current day is a rest day based on the absence of scheduled workouts.
  # @return [Boolean] True if it is a rest day (no workouts scheduled), otherwise false.
  def is_rest_day?
    !is_workout_scheduled?
  end

  # Checks if there are any bike workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are bike workouts scheduled, otherwise false.
  def is_bike_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Bike' }
  end

  # Checks if there are any running workouts scheduled in TrainerRoad or Runna.
  # @return [Boolean] True if there are running workouts scheduled, otherwise false.
  def is_run_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Run' } || data.runna.workouts.any?
  end

  # Checks if there are any swimming workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are swimming workouts scheduled, otherwise false.
  def is_swim_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Swim' }
  end
end
