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

  it_behaves_like "a live-update fragment", "/widgets/activity-stats"

  # The live-update contract: an upstream that fails gives an empty fragment, and never a 500.
  it "renders the empty body, with no stale-while-revalidate for the browser, when Intervals.icu times out" do
    allow_any_instance_of(Intervals).to receive(:stats).and_raise(Net::ReadTimeout)

    get "/widgets/activity-stats", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("")
    expect(response.headers["Cache-Control"]).to include("must-revalidate")
    expect(response.headers["Cache-Control"]).not_to include("stale-while-revalidate")
    expect(response.headers["CDN-Cache-Control"]).to eq("public, max-age=60")
  end

  it "renders the stats markup" do
    get "/widgets/activity-stats", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("stats__heading")
    expect(response.body).to include("Monthly Totals")
    expect(response.body).to include("46")        # total activities, delimited
    expect(response.body).to include("Swimming")
    expect(response.body).to include("<svg")       # icon markup is rendered unescaped
    expect(response.body).to include('Intervals.icu<span class="sr-only"> (opens in a new tab)</span></a>')
  end

  it "sets the caching headers" do
    get "/widgets/activity-stats", headers: auth_headers

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=300")

    # The edge policy, in the RFC 9213 form that Cloudflare reads. It must never use s-maxage,
    # because that directive stops stale-while-revalidate and stale-if-error.
    cdn = response.headers["CDN-Cache-Control"]
    expect(cdn).to include("public")
    expect(cdn).to include("max-age=300")
    expect(cdn).to include("stale-while-revalidate=3600")
    expect(cdn).to include("stale-if-error=86400")
    expect(cdn).not_to include("s-maxage")
  end

  it "embeds a relative same-origin refetch URL" do
    get "/widgets/activity-stats", headers: auth_headers

    expect(response.body).to include('data-live-update-url-value="/widgets/activity-stats"')
  end

  it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
    get "/widgets/activity-stats"
    expect(response).to have_http_status(:unauthorized)

    get "/widgets/activity-stats", headers: { "Authorization" => "Bearer wrong" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "when the stats are unavailable" do
    before { allow_any_instance_of(Intervals).to receive(:stats).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/widgets/activity-stats", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end

    it "downgrades the edge cache to a short TTL so a blip doesn't pin the empty response" do
      get "/widgets/activity-stats", headers: auth_headers

      edge = response.headers["CDN-Cache-Control"]
      expect(edge).to eq("public, max-age=60")
      # There is no directive for an old copy: the edge must never serve an empty response after
      # its one minute.
      expect(edge).not_to include("stale-while-revalidate")
      expect(edge).not_to include("stale-if-error")
    end
  end
end
