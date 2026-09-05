require "rails_helper"

RSpec.describe TrendingInspector do
  subject(:inspector) { described_class.new(trending: trending, plausible: plausible) }

  let(:trending) { instance_double(TrendingArticles) }
  let(:today) { Date.new(2024, 6, 15) }
  let(:series) { { "/2024/01/01/a/" => { today => 3 } } }
  let(:plausible) { instance_double(Plausible, site_today: today, daily_visitors_by_path: series) }

  def row(id, status: :fill)
    { article: DeepOstruct.wrap(sys: { id: id }, title: id), status: status }
  end

  describe "#inspect_list" do
    it "gives the rows of the ranking as of today" do
      allow(trending).to receive(:evaluate).and_return([ row("a") ])

      expect(inspector.inspect_list.map { |r| r[:article].sys.id }).to eq(%w[a])
    end
  end

  describe "#replay" do
    # ⚠️ One series serves each day. It reaches back the days of the replay past the usual series.
    it "asks for one series that reaches back far enough" do
      allow(trending).to receive(:evaluate).and_return([])

      inspector.replay(days: 3)

      expect(plausible).to have_received(:daily_visitors_by_path).with(days: TrendingArticles::SERIES_DAYS + 3, today: today)
    end

    it "gives the list of each day, without the newest articles, and counts the changes" do
      lists = {
        today - 2 => [ row("a"), row("b"), row("new", status: :recent) ],
        today - 1 => [ row("a"), row("c") ],
        today => [ row("d"), row("c") ]
      }
      allow(trending).to receive(:evaluate) { |today:, series:| lists.fetch(today) }

      report = inspector.replay(days: 3)

      expect(report[:days].map { |day| day[:date] }).to eq([ today - 2, today - 1, today ])
      expect(report[:days].first[:rows].map { |r| r[:article].sys.id }).to eq(%w[a b])
      expect(report[:changes]).to eq(1.0)
    end

    it "gives no days when the series is not available" do
      allow(plausible).to receive(:daily_visitors_by_path).and_return(nil)

      expect(inspector.replay(days: 3)).to eq(days: [], changes: 0.0)
    end
  end
end
