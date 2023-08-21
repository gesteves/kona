module WorkoutsHelpers
  def is_workout_scheduled?
    data.trainerroad.workouts.present?
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
end
