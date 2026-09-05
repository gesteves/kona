# The reports of `rake trending:inspect` and `rake trending:replay`.
#
# ⚠️ No A/B test can operate at the traffic of this site. Thus these two reports are the only
# method to know if a change to a setting of TrendingArticles helped. Both call
# TrendingArticles#evaluate, thus a report can never describe a different list.
class TrendingInspector
  # The number of cards that the widget renders.
  WIDGET_COUNT = 4

  def initialize(trending: TrendingArticles.new, plausible: Plausible.new)
    @trending = trending
    @plausible = plausible
  end

  # Each candidate with its numbers, as of today.
  # @return [Array<Hash>] The rows of TrendingArticles#evaluate.
  def inspect_list
    @trending.evaluate
  end

  # The list as of each of the last `days` days, from one series that reaches that far back.
  # @param days [Integer]
  # @return [Hash] { days: [ { date:, rows: } ], changes: } where `changes` is the mean number of
  #   new entries in the top WIDGET_COUNT from one day to the next.
  def replay(days:)
    today = @plausible.site_today
    series = @plausible.daily_visitors_by_path(days: TrendingArticles::SERIES_DAYS + days, today: today)
    return { days: [], changes: 0.0 } if series.nil?

    previous = nil
    changes = 0
    reports = (days - 1).downto(0).map do |offset|
      date = today - offset
      rows = @trending.evaluate(today: date, series: series).reject { |row| row[:status] == :recent }.first(WIDGET_COUNT)
      ids = rows.map { |row| row[:article].sys&.id }
      changes += (ids - previous).size if previous
      previous = ids
      { date: date, rows: rows }
    end

    { days: reports, changes: days > 1 ? (changes.to_f / (days - 1)).round(2) : 0.0 }
  end
end
