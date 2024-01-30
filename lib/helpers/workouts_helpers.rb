module WorkoutsHelpers
  # Checks if there are any workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are scheduled workouts, otherwise false.
  def is_workout_scheduled?
    data.trainerroad.workouts.present?
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

  # Checks if there are any running workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are running workouts scheduled, otherwise false.
  def is_run_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Run' }
  end

  # Checks if there are any swimming workouts scheduled in TrainerRoad.
  # @return [Boolean] True if there are swimming workouts scheduled, otherwise false.
  def is_swim_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Swim' }
  end

  # Formats and combines activity totals for swimming, cycling, and running.
  # @param swims [Integer] The number of swimming activities.
  # @param rides [Integer] The number of cycling activities.
  # @param runs [Integer] The number of running activities.
  # @param separator [String] (Optional) The separator to use between activity totals. Default is " | ".
  # @return [String] A formatted string containing combined activity totals.
  def formatted_activity_totals(swims, rides, runs, separator = " | ")
    activities = []

    activities << "#{swims} #{'swim'.pluralize(swims)}" unless swims.zero?
    activities << "#{rides} #{'ride'.pluralize(rides)}" unless rides.zero?
    activities << "#{runs} #{'run'.pluralize(runs)}" unless runs.zero?

    activities.join(separator)
  end

  # Checks if it's indoor training season in Jackson Hole.
  # Indoor season is from November through March.
  # @return [Boolean] True if it's indoor season, false otherwise.
  def is_indoor_season?
    in_jackson_hole? && (Time.now.month <= 3 || Time.now.month >= 11)
  end
end
