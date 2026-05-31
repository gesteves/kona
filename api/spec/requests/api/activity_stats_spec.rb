require "rails_helper"

RSpec.describe "Activity stats", type: :request do
  let(:stats) do
    {
      swim_distance: 17373.6,
      bike_distance: 1195565.21,
      run_distance: 159902.58,
      total_activities: 46
    }
  end

  before do
    allow_any_instance_of(Intervals).to receive(:stats).and_return(stats)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the stats markup" do
    get "/api/activity-stats"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("stats__heading")
    expect(response.body).to include("Monthly Totals")
    expect(response.body).to include("46")        # total activities, delimited
    expect(response.body).to include("Swimming")
    expect(response.body).to include("<svg")       # icon markup is rendered unescaped
  end

  it "sets the caching headers" do
    get "/api/activity-stats"

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=300")

    edge = response.headers["Netlify-CDN-Cache-Control"]
    expect(edge).to include("durable")
    expect(edge).to include("max-age=300")
    expect(edge).to include("stale-while-revalidate=86400")
    expect(edge).to include("stale-if-error=86400")
  end

  it "embeds a relative same-origin refetch URL" do
    get "/api/activity-stats"

    expect(response.body).to include('data-live-update-url-value="/api/activity-stats"')
  end

  context "when the stats are unavailable" do
    before { allow_any_instance_of(Intervals).to receive(:stats).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/api/activity-stats"

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end

    it "downgrades the edge cache to a short, non-durable TTL so a blip doesn't pin the empty response" do
      get "/api/activity-stats"

      edge = response.headers["Netlify-CDN-Cache-Control"]
      expect(edge).to eq("public, max-age=60")
      expect(edge).not_to include("durable")
    end
  end
end
