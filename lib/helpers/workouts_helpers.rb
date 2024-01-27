module WorkoutsHelpers
  # Checks if there are any workouts scheduled in the TrainerRoad data.
  # @return [Boolean] True if there are scheduled workouts, otherwise false.
  def is_workout_scheduled?
    data.trainerroad.workouts.present?
  end

  # Determines if the current day is a rest day based on the absence of scheduled workouts.
  # @return [Boolean] True if it is a rest day (no workouts scheduled), otherwise false.
  def is_rest_day?
    !is_workout_scheduled?
  end

  # Checks if there are any bike workouts scheduled in the TrainerRoad data.
  # @return [Boolean] True if there are bike workouts scheduled, otherwise false.
  def is_bike_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Bike' }
  end

  # Checks if there are any running workouts scheduled in the TrainerRoad data.
  # @return [Boolean] True if there are running workouts scheduled, otherwise false.
  def is_run_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Run' }
  end

  # Checks if there are any swimming workouts scheduled in the TrainerRoad data.
  # @return [Boolean] True if there are swimming workouts scheduled, otherwise false.
  def is_swim_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Swim' }
  end

  # Determines the appropriate indefinite article ('a' or 'an') to use with a workout description.
  # @param workout [Object] The workout object with a description.
  # @return [String] The workout description prefixed with the appropriate indefinite article.
  def workout_with_article(workout)
    workout.description =~ /^(8|11|18|80)-/i ? "an #{workout.description}" : "a #{workout.description}"
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

end
