module ActivityDescription
  # The name of one leg of a triathlon on race day: "<race name> – Swim", "– T1", "– Bike", "– T2",
  # or "– Run". These are functions with no I/O.
  #
  # The legs come in one of two shapes:
  #
  # - **One multisport file.** The legs of one Garmin multisport file share one `external_id`, and
  #   Intervals.icu imports the whole file at one time. That group, in the order of the start times,
  #   gives each label, transitions included.
  # - **Separate files**, when the swim is cancelled: a ride and a run, from one device or from two.
  #   There is no transition. The run is the first run that starts after a ride, and the bike is the
  #   last ride that starts before that run. Thus a warm-up run before the bike, a ride to the
  #   start, and a cool-down run after the race keep their usual names.
  module RaceLeg
    # @!attribute name [String] The name of the leg.
    # @!attribute partner_id [String, nil] The other leg of a pair of separate files. Its own run
    #   came before this leg arrived, thus it needs one more run to get its name.
    Leg = Data.define(:name, :partner_id)

    # The label of each leg that is not a transition, from the standard type of ActivityMatcher.
    LABELS = { "Swimming" => "Swim", "Cycling" => "Bike", "Running" => "Run" }.freeze

    module_function

    # @param activity [Hash] The Intervals.icu activity.
    # @param day_activities [Array<Hash>] The Intervals.icu activities of its date.
    # @param race_name [String, nil] The race of that date, from TrainerRoad#race_name.
    # @return [Leg, nil] The leg, or nil when the activity is not a leg of the race.
    def find(activity, day_activities:, race_name:)
      return if race_name.blank?

      group = multisport_group(activity, day_activities)
      if group
        label = label_in_group(group, group.index { |candidate| candidate[:id] == activity[:id] })
        return label && Leg.new(name: "#{race_name} – #{label}", partner_id: nil)
      end

      separate_leg(activity, day_activities, race_name)
    end

    # @return [Array<Hash>, nil] The legs of the multisport file of the activity, in order, or nil
    #   when the activity is alone in its file.
    def multisport_group(activity, day_activities)
      return if activity[:external_id].blank?

      group = day_activities.select { |candidate| candidate[:external_id] == activity[:external_id] }
      group.sort_by { |candidate| candidate[:start_date].to_s } if group.size > 1
    end

    # A transition is T1 after the swim and T2 after the bike. A race with no swim starts with the
    # bike, thus its one transition comes after the bike and is T2. With no leg before it, the next
    # leg decides: T1 before the bike.
    # @return [String, nil]
    def label_in_group(group, index)
      return if index.nil?

      leg = group[index]
      return LABELS[sport(leg)] unless transition?(leg)

      before = group[0...index].reverse.find { |candidate| !transition?(candidate) }
      return { "Swimming" => "T1", "Cycling" => "T2" }[sport(before)] if before

      after = group[(index + 1)..].find { |candidate| !transition?(candidate) }
      "T1" if after && sport(after) == "Cycling"
    end

    # The bike and the run of a race in separate files. Each activity of a multisport file is out of
    # this search.
    # @return [Leg, nil]
    def separate_leg(activity, day_activities, race_name)
      singles = day_activities.reject { |candidate| multisport_group(candidate, day_activities) }
                              .sort_by { |candidate| candidate[:start_date].to_s }
      rides = singles.select { |candidate| sport(candidate) == "Cycling" }
      return if rides.empty?

      run = singles.find do |candidate|
        sport(candidate) == "Running" && candidate[:start_date].to_s > rides.first[:start_date].to_s
      end
      return if run.nil?

      ride = rides.reverse.find { |candidate| candidate[:start_date].to_s < run[:start_date].to_s }

      if activity[:id] == ride[:id]
        Leg.new(name: "#{race_name} – Bike", partner_id: run[:id])
      elsif activity[:id] == run[:id]
        Leg.new(name: "#{race_name} – Run", partner_id: ride[:id])
      end
    end

    def transition?(activity) = activity[:type].to_s.casecmp("transition").zero?

    def sport(activity) = ActivityMatcher.normalize_type(activity[:type])
  end
end
