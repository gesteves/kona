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

  # ⚠️ The edge does not cache this, on purpose: the build gets it one time, immediately after the
  # publish that started the build. Thus a copy in the cache would be wrong in the one condition
  # that is important.
  it "sets no edge cache policy" do
    allow_any_instance_of(RelatedArticles).to receive(:all).and_return({})

    get "/api/related", headers: auth_headers

    expect(response.headers["CDN-Cache-Control"]).to be_nil
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "returns an empty object rather than failing when nothing is ranked" do
    allow_any_instance_of(RelatedArticles).to receive(:all).and_return({})

    get "/api/related", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq({})
  end
end
