require "rails_helper"

RSpec.describe "Whoop", type: :request do
  let(:stats) do
    {
      physiological_cycle: { id: 100, score: { strain: 12.3458 } },
      sleep: { id: 200, end: "2026-05-30T13:00:00.000Z", score: { sleep_performance_percentage: 92.4 } },
      recovery: { score: { recovery_score: 55.6 } }
    }
  end

  before do
    # Avoid touching Redis / Google Maps for the timezone; fall back to the default.
    allow(Location).to receive(:new).and_return(instance_double(Location, latitude: nil, longitude: nil))
    allow_any_instance_of(TrainerRoad).to receive(:workouts).and_return([])
    allow_any_instance_of(Whoop).to receive(:stats).and_return(stats)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the Whoop markup" do
    get "/api/whoop", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("stats__heading")
    expect(response.body).to include("Whoop")
    expect(response.body).to include("Sleep")
    expect(response.body).to include("92")        # sleep score, rounded
    expect(response.body).to include("Recovery")
    expect(response.body).to include("56")        # recovery score, rounded
    expect(response.body).to include("Strain")
    expect(response.body).to include("12.3")      # strain score, one decimal
    expect(response.body).to include("<svg")      # icon markup is rendered unescaped
  end

  it "sets the caching headers" do
    get "/api/whoop", headers: auth_headers

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
    get "/api/whoop", headers: auth_headers

    expect(response.body).to include('data-live-update-url-value="/api/whoop"')
  end

  context "when the stats are unavailable" do
    before { allow_any_instance_of(Whoop).to receive(:stats).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/api/whoop", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end
end
