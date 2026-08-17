require "rails_helper"

RSpec.describe "Api::Icons", type: :request do
  let(:token) { "test-token" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
  end

  def post_icons(body, headers: { "Authorization" => "Bearer #{token}" })
    post "/api/icons", params: body.to_json, headers: headers.merge("Content-Type" => "application/json")
  end

  it "rejects requests without a bearer token before resolving any icon" do
    expect_any_instance_of(FontAwesome).not_to receive(:svg)

    post_icons({ icons: { "classic" => { "solid" => %w[heart] } } }, headers: {})

    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with the wrong bearer token" do
    post_icons({ icons: { "classic" => { "solid" => %w[heart] } } },
      headers: { "Authorization" => "Bearer nope" })

    expect(response).to have_http_status(:unauthorized)
  end

  it "resolves the posted allowlist to SVGs, preserving order and omitting misses" do
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return(nil)
    allow_any_instance_of(FontAwesome).to receive(:svg)
      .with("classic", "solid", "heart").and_return("<svg>heart</svg>")
    allow_any_instance_of(FontAwesome).to receive(:svg)
      .with("classic", "solid", "check").and_return("<svg>check</svg>")
    # A miss (nil) — must be omitted from the response entirely.
    allow_any_instance_of(FontAwesome).to receive(:svg)
      .with("classic", "light", "no-such-icon").and_return(nil)

    post_icons({ icons: {
      "classic" => {
        "solid" => %w[heart check],
        "light" => %w[no-such-icon]
      }
    } })

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "classic" => {
        "solid" => [
          { "id" => "heart", "svg" => "<svg>heart</svg>" },
          { "id" => "check", "svg" => "<svg>check</svg>" }
        ]
      }
    )
  end

  it "emits an id repeated within a family/style only once" do
    allow_any_instance_of(FontAwesome).to receive(:svg)
      .with("classic", "light", "wind").and_return("<svg>wind</svg>")

    post_icons({ icons: { "classic" => { "light" => %w[wind wind] } } })

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "classic" => { "light" => [ { "id" => "wind", "svg" => "<svg>wind</svg>" } ] }
    )
  end

  it "returns 422 when the body carries no icons tree" do
    expect_any_instance_of(FontAwesome).not_to receive(:svg)

    post_icons({ icons: "nope" })

    expect(response).to have_http_status(:unprocessable_content)
  end

  # ⚠️ Every miss here is a billed upstream call and a Redis key that lives for a year. The web
  # build posts in batches of 25, but that's the caller's convention — this is the ceiling.
  it "refuses an oversized tree before making a single upstream call" do
    expect_any_instance_of(FontAwesome).not_to receive(:svg)

    ids = Array.new(Api::IconsController::MAX_ICONS + 1) { |i| "icon-#{i}" }
    post_icons({ icons: { "classic" => { "solid" => ids } } })

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error"]).to include("Too many icons")
  end

  # A family, style, or id outside Font Awesome's identifier shape can't name a real icon, so it
  # must never reach the upstream — or mint a cache key built by interpolating it.
  it "drops segments that can't name a real icon, without asking upstream about them" do
    allow_any_instance_of(FontAwesome).to receive(:svg)
      .with("classic", "solid", "heart").and_return("<svg>heart</svg>")
    expect_any_instance_of(FontAwesome).not_to receive(:svg).with("classic", "solid", "../../etc")

    post_icons({ icons: {
      "classic" => { "solid" => [ "heart", "../../etc", "with space", "" ] },
      "Bad Family" => { "solid" => %w[heart] }
    } })

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "classic" => { "solid" => [ { "id" => "heart", "svg" => "<svg>heart</svg>" } ] }
    )
  end
end
