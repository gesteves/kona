# The tool to check the weather line of the activity description.
#
# ⚠️ It writes nothing. Use it to tune ActivityDescription::Weather, and to check the line of an
# activity before the job writes it.
namespace :activity_weather do
  desc "Prints the WeatherKit summary of each activity, its emoji, and the sentence that the LLM " \
       "writes from it. Give the Intervals.icu ids, for example rake \"activity_weather:inspect[i123,i456]\"."
  task :inspect, [ :ids ] => :environment do |_task, args|
    ids = [ args[:ids], *args.extras ].compact_blank
    abort("Give one or more Intervals.icu activity ids.") if ids.empty?

    intervals = Intervals.new
    unit = intervals.temperature_unit
    llm = ActivityDescription::Llm.configured?
    puts "No ANTHROPIC_API_KEY: the task prints the data only." unless llm

    ids.each do |id|
      activity = intervals.activity!(id)
      swim = ActivityMatcher.normalize_type(activity[:type]) == "Swimming"
      streams = intervals.activity_streams(id, types: %w[latlng time])
      weather = ActivityDescription::Weather.new(activity, streams, unit: unit, headwind: !swim)
      summary = weather.summary

      puts
      puts "== #{id} · #{activity[:name]} · #{activity[:start_date_local]}"
      puts summary ? JSON.pretty_generate(summary) : "(no weather)"
      next unless llm && summary

      puts [ weather.emoji, ActivityDescription::Llm.weather_sentence(summary) || "(no sentence)" ].compact.join(" ")
    end
  end
end
