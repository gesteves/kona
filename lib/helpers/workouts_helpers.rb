module WorkoutsHelpers
  def is_workout_scheduled?
    data.trainerroad.workouts.present?
  end

  def no_workout_scheduled?
    !is_workout_scheduled?
  end

  def is_bike_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Bike' }
  end

  def is_run_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Run' }
  end

  def is_swim_scheduled?
    data.trainerroad.workouts.any? { |w| w.discipline == 'Swim' }
  end

  def workout_with_article(workout)
    workout.description =~ /^(8|11|18|80)-/i ? "an #{workout.description}" : "a #{workout.description}"
  end

  def formatted_activity_totals(swims, rides, runs, separator = " | ")
    activities = []

    activities << "#{swims} #{'swim'.pluralize(swims)}" unless swims.zero?
    activities << "#{rides} #{'ride'.pluralize(rides)}" unless rides.zero?
    activities << "#{runs} #{'run'.pluralize(runs)}" unless runs.zero?

    activities.join(separator)
  end

end
