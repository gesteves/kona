# The tool to check the weather line of the activity description.
#
# ⚠️ It writes nothing. Use it to tune ActivityDescription::Weather and WeatherSentence, and to check
# the line of an activity before the job writes it.
namespace :activity_weather do
  desc "Prints the WeatherKit summary of each activity and its weather line. Give the Intervals.icu " \
       "ids, for example rake \"activity_weather:inspect[i123,i456]\"."
  task :inspect, [ :ids ] => :environment do |_task, args|
    ids = [ args[:ids], *args.extras ].compact_blank
    abort("Give one or more Intervals.icu activity ids.") if ids.empty?

    intervals = Intervals.new
    unit = intervals.temperature_unit

    ids.each do |id|
      activity = intervals.activity!(id)
      puts
      puts "== #{id} · #{activity[:name]} · #{activity[:start_date_local]}"
      if ActivityDescription::Generator.indoor?(activity)
        puts "(indoor: no weather line)"
        next
      end

      streams = intervals.activity_streams(id, types: %w[latlng time])
      headwind = ActivityDescription::Weather.headwind?(activity)
      weather = ActivityDescription::Weather.new(activity, streams, unit: unit, headwind: headwind, intervals: intervals)
      summary = weather.summary

      track = weather.track_weather
      puts "WeatherKit: #{track.calls} calls, #{track.query_points.size} query points" if track
      puts summary ? JSON.pretty_generate(summary) : "(no weather)"
      next unless summary

      if weather.headwind_share
        puts "Headwind: #{weather.headwind_share}% of the moving time (the line shows it from " \
             "#{ActivityDescription::Weather::HEADWIND_MIN_PERCENT}%)"
      end

      puts [ weather.emoji, ActivityDescription::WeatherSentence.call(summary) ].compact.join(" ")
      changing = summary[:conditions] && ActivityDescription::Llm.weather_conditions(summary[:conditions])
      puts "LLM: #{[ weather.emoji, ActivityDescription::WeatherSentence.call(summary, changing) ].compact.join(' ')}" if changing
    end
  end
end
