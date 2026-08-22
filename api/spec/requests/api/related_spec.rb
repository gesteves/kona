require "rails_helper"

RSpec.describe "Api::Related", type: :request do
  it "requires the bearer token, like the other build-time endpoints" do
    expect_any_instance_of(RelatedArticles).not_to receive(:all)

    get "/api/related"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the whole ranking as Contentful ids" do
    ranking = { "id-a" => %w[id-b id-c], "id-b" => %w[id-a] }
    allow_any_instance_of(RelatedArticles).to receive(:all).and_return(ranking)

    get "/api/related", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(ranking)
  end

  it "asks for as many neighbors as the section renders" do
    expect_any_instance_of(RelatedArticles).to receive(:all)
      .with(count: Api::RelatedController::COUNT).and_return({})

    get "/api/related", headers: auth_headers
  end

  # ⚠️ Not edge-cached on purpose: it's fetched once per build, right after the publish that
  # triggered it, so a cached copy would be wrong in exactly the case that matters.
  it "sets no edge cache policy" do
    allow_any_instance_of(RelatedArticles).to receive(:all).and_return({})

    get "/api/related", headers: auth_headers

    expect(response.headers["CDN-Cache-Control"]).to be_nil
  end

  it "returns an empty object rather than failing when nothing is ranked" do
    allow_any_instance_of(RelatedArticles).to receive(:all).and_return({})

    get "/api/related", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq({})
  end
end
