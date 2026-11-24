module ActivityDescription
  # The conditions of an activity in time order: the runs of one condition code, the main
  # condition, and the facts that the LLM joins into words. Code decides each fact and each word.
  class ConditionRuns
    # A condition that is shorter than this is noise, and the sequence omits it.
    MIN_CONDITION_SECONDS = 900
    # The sky-cover codes that are almost the same. The main condition is the family with the most
    # time, named by its code with the most time. Each other code is a family of its own.
    SKY_FAMILIES = { "Clear" => :clear, "MostlyClear" => :clear, "PartlyCloudy" => :cloudy, "MostlyCloudy" => :cloudy }.freeze

    # The most facts that the LLM gets. The facts after this number go away, thus the order of
    # #facts is the order of importance.
    MAX_FACTS = 3
    # The most precipitation facts, one for each type.
    MAX_PRECIPITATION_FACTS = 2
    # The words of a share of the time, as [the lowest share, the words].
    SHARE_WORDS = [ [ 0.9, "the whole time" ], [ 0.6, "most of the time" ], [ 0.2, "part of the time" ], [ 0.0, "briefly" ] ].freeze
    # From this share, the precipitation already says the sky, thus the facts have no sky.
    SKY_HIDDEN_SHARE = 0.6
    # The word of the mean wind speed, as [the lowest km/h, the word]: the start of Beaufort 5, 4,
    # and 3. Below the last step, the facts have no wind. These are one step below the names of
    # the scale, on purpose: a person on a bike feels a "moderate breeze" as windy.
    WIND_WORDS = [ [ 29, "very windy" ], [ 20, "windy" ], [ 12, "breezy" ] ].freeze
    # The codes that give an air fact.
    AIR_CODES = %w[Fog Haze Smoke Dust BlowingDust].freeze
    # The codes whose words already say the wind. With one of them, the facts have no wind.
    WINDY_CODES = %w[Blizzard BlowingSnow BlowingDust].freeze

    # @param samples [Array<Hash>] The samples of the track with weather, in time order, each with
    #   :offset, :seconds, and :weather.
    def initialize(samples)
      @runs = merge_short(consecutive(samples))
    end

    # The condition code of the SKY_FAMILIES family with the most time, and whether most of that
    # time was in daylight. Thus 30% clear and 25% mostly clear win against 45% partly cloudy.
    # ⚠️ It reads the runs and not the samples, thus a short run that joined its neighbor cannot be
    # the main condition.
    # @return [Hash, nil] { code:, daylight: }, or nil with no condition.
    def main
      return @main if defined?(@main)

      @main = main_of(@runs)
    end

    # The precipitation of another TYPE than the main condition, for part of the activity, as
    # { condition: }. Its word is the longest condition of that type. With more than one such type,
    # the one with the most time. The line gives no time: an hourly code cannot give minutes.
    # ⚠️ The type is what stops a repeat: rain with 20 minutes of drizzle is one type, thus the line
    # says "Rain" alone.
    # @return [Hash, nil]
    def precipitation_spell
      main_type = main && ConditionCodes.precipitation_type(main[:code])
      by_type = @runs.group_by { |run| ConditionCodes.precipitation_type(run[:code]) }
                     .reject { |type, _group| type.nil? || type == main_type }
      return if by_type.empty?

      _type, spell = by_type.max_by { |_key, group| seconds_of(group) }
      { condition: ConditionCodes.phrase(longest_code(spell)).downcase }
    end

    # The facts of the conditions, for the LLM, in the order of importance: the precipitation, the
    # wind, the air, and the sky.
    # ⚠️ The Breezy, Windy, Hot, and Frigid codes give no fact: the wind speed gives the wind word,
    # and the line gives the temperature as numbers.
    # @param wind_kph [Float, nil] The mean wind speed of the activity.
    # @param cloud_cover [Float, nil] The mean cloud cover of the activity, from 0 to 1.
    # @return [Array<Array(String, String)>] Each fact as [label, words], MAX_FACTS at the most.
    #   Empty with no runs, or with a code that config/conditions.yml does not have: that code can
    #   be precipitation, and the facts would omit it.
    def facts(wind_kph:, cloud_cover:)
      return [] if @runs.empty? || @runs.any? { |run| !ConditionCodes.known?(run[:code]) }

      precipitation = run_facts { |code| ConditionCodes.precipitation_type(code) }.first(MAX_PRECIPITATION_FACTS)
      facts = precipitation.map { |fact| [ "Precipitation", fact[:words] ] }

      wind = wind_word(wind_kph) unless @runs.any? { |run| WINDY_CODES.include?(run[:code]) }
      facts << [ "Wind", wind ] if wind
      facts.concat(run_facts { |code| code if AIR_CODES.include?(code) }.map { |fact| [ "Air", fact[:words] ] })

      sky = sky_word(cloud_cover)
      facts << [ "Sky", sky ] if sky && precipitation.none? { |fact| fact[:share] >= SKY_HIDDEN_SHARE }
      facts.first(MAX_FACTS)
    end

    private

    # @return [Array<Hash>] One run for each stretch of one code, as { code:, seconds:, night:,
    #   first:, last: }. A sample with no code is in no run.
    def consecutive(samples)
      runs = []
      samples.each do |sample|
        code = sample[:weather][:conditionCode].presence
        next if code.nil?

        night = sample[:weather][:daylight] == false ? sample[:seconds] : 0
        if runs.last && runs.last[:code] == code
          extend_run(runs.last, seconds: sample[:seconds], night: night, last: sample[:offset])
        else
          runs << { code: code, seconds: sample[:seconds], night: night, first: sample[:offset], last: sample[:offset] }
        end
      end
      runs
    end

    # A run shorter than MIN_CONDITION_SECONDS joins the run before it, or the run after it at the
    # start.
    def merge_short(runs)
      merged = []
      runs.each do |run|
        if merged.any? && (run[:seconds] < MIN_CONDITION_SECONDS || merged.last[:code] == run[:code])
          extend_run(merged.last, **run.slice(:seconds, :night, :last))
        else
          merged << run.dup
        end
      end
      if merged.size > 1 && merged.first[:seconds] < MIN_CONDITION_SECONDS
        first = merged.shift
        merged.first[:first] = first[:first]
        merged.first[:seconds] += first[:seconds]
        merged.first[:night] += first[:night]
      end
      merged
    end

    def extend_run(run, seconds:, night:, last:)
      run[:seconds] += seconds
      run[:night] += night
      run[:last] = last
    end

    def main_of(runs)
      return if runs.empty?

      _family, family_runs = runs.group_by { |run| SKY_FAMILIES.fetch(run[:code], run[:code]) }.max_by { |_key, same| seconds_of(same) }
      code, group = family_runs.group_by { |run| run[:code] }.max_by { |_code, same| seconds_of(same) }
      { code: code, daylight: group.sum { |run| run[:night] } * 2 <= seconds_of(group) }
    end

    def seconds_of(runs) = runs.sum { |run| run[:seconds] }

    # @return [String] The code with the most time in the runs.
    def longest_code(runs)
      runs.group_by { |run| run[:code] }.max_by { |_code, same| seconds_of(same) }.first
    end

    # One fact for each key of the runs, as { words:, share: }, most time first. The words are the
    # phrase of the code with the most time, the SHARE_WORDS of the key, and "on and off" when the
    # key has more than one stretch.
    # ⚠️ Only a run with no key ends a stretch. Rain, then a thunderstorm, then rain is one stretch
    # of rain: it did not stop.
    # @yieldparam code [String] The condition code of a run.
    # @yieldreturn [Object, nil] The key of the run, or nil for a run that gives no fact.
    def run_facts
      total = seconds_of(@runs)
      keyed = @runs.map { |run| [ yield(run[:code]), run ] }
      stretches = keyed.slice_when { |(a, _), (b, _)| a.nil? || b.nil? }.flat_map { |chunk| chunk.filter_map(&:first).uniq }.tally

      keyed.select(&:first).group_by(&:first).map do |key, pairs|
        group = pairs.map(&:last)
        share = seconds_of(group) / total.to_f
        words = [ ConditionCodes.fact_phrase(longest_code(group)), SHARE_WORDS.find { |limit, _words| share >= limit }.last ]
        words << "on and off" if stretches[key] > 1
        { words: words.join(", "), share: share }
      end.sort_by { |fact| -fact[:share] }
    end

    # @return [String, nil] The WIND_WORDS word of a mean wind speed, or nil below the last step.
    def wind_word(kph)
      kph && WIND_WORDS.find { |limit, _word| kph >= limit }&.last
    end

    # The sky word: the main condition of the runs with a sky code, by the rule of #main. Thus the
    # word agrees with the emoji. With no such run, the mean cloud cover gives the word.
    # @return [String, nil] Nil with no sky run and no cloud cover.
    def sky_word(cloud_cover)
      sky = @runs.select { |run| ConditionCodes::SKY_CODES.include?(run[:code]) }
      return ConditionCodes.fact_phrase(main_of(sky)[:code]) if sky.any?

      cloud_cover && ConditionCodes.fact_phrase(ConditionCodes.for_cloud_cover(cloud_cover * 100))
    end
  end
end
