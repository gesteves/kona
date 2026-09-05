# The inspection tools for the "Trending Articles" ranking.
#
# ⚠️ These exist because no A/B test can operate at the traffic of this site. Thus a person reads
# these two reports to know if a change to a setting helped.
namespace :trending do
  desc "Prints each candidate with its visitors, its expected visitors, and its surprise for " \
       "each window, its visitors of the last 30 days, its visitors of all time, and its status."
  task inspect: :environment do
    rows = TrendingInspector.new.inspect_list
    windows = TrendingArticles::WINDOWS

    header = [ "#", "status" ] + windows.flat_map { |days| [ "#{days}d", "exp", "surprise" ] } + [ "30d", "all", "title" ]
    puts format("%-4s %-7s " + ("%-5s %-7s %-8s " * windows.size) + "%-6s %-7s %s", *header)

    rows.each_with_index do |row, index|
      cells = windows.flat_map do |days|
        stats = row[:windows][days]
        [ stats[:visitors], stats[:expected] ? format("%.1f", stats[:expected]) : "-", stats[:surprise] ? format("%.1f", stats[:surprise]) : "-" ]
      end
      puts format("%-4d %-7s " + ("%-5d %-7s %-8s " * windows.size) + "%-6d %-7d %s",
                  index + 1, row[:status], *cells, row[:recent], row[:popularity], row[:article].title)
    end
  end

  desc "Prints the list as of each of the last N days (default 35), and how much it changed."
  task :replay, [ :days ] => :environment do |_task, args|
    days = Integer(args[:days].presence || 35)
    report = TrendingInspector.new.replay(days: days)
    abort("No series. Plausible is not configured, or it is not available.") if report[:days].empty?

    report[:days].each do |day|
      puts
      puts day[:date].iso8601
      day[:rows].each do |row|
        label =
          if row[:status] == :trend
            days_of = row[:windows].find { |_days, stats| stats[:surprise] == row[:trend] }&.first
            stats = row[:windows][days_of]
            format("trend %dd: %d visitors, expected %.1f, surprise %.1f", days_of, stats[:visitors], stats[:expected], stats[:surprise])
          else
            "fill: #{row[:recent]} visitors in #{TrendingArticles::FILL_DAYS} days"
          end
        puts format("   %-50.50s %s", row[:article].title, label)
      end
    end

    puts
    puts "new entries in the top #{TrendingInspector::WIDGET_COUNT} for each day: #{report[:changes]}"
  end
end
