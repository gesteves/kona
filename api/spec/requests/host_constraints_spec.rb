require "rails_helper"

# The public API hostname serves only /up and the three machine namespaces; everything
# owner-facing is drawn behind the `API_HOST` constraint in config/routes.rb.
#
# ⚠️ This is what makes the zone's bot-protection skip rule ("skip every host except the admin
# one") safe. An owner-facing route reachable on the public host would sit there with managed
# rules and Super Bot Fight Mode skipped, and nothing in the zone would catch it.
RSpec.describe "Public API host route constraints", type: :request do
  api_host = "api.example.test"
  admin_host = "admin.example.test"

  owner_paths = [
    [ :get,  "/whoop/auth" ],
    [ :get,  "/whoop/callback" ],
    [ :get,  "/login" ],
    [ :post, "/logout" ],
    [ :get,  "/auth/google_oauth2/callback" ],
    [ :get,  "/auth/failure" ],
    [ :get,  "/sidekiq" ]
  ]

  # One per namespace the public host must keep answering. Most are bearer- or HMAC-gated and
  # answer 401 here, which is the point: any status but 404 proves the route still exists.
  public_paths = [
    [ :get,  "/up" ],
    [ :get,  "/widgets/whoop" ],
    [ :get,  "/widgets/articles/trending" ],
    [ :get,  "/api/standard-site" ],
    [ :post, "/api/build" ],
    [ :post, "/webhooks/contentful" ],
    [ :get,  "/" ]
  ]

  # The two paths that reach a controller body rather than a gate: the OmniAuth callback needs a
  # mocked auth hash, and the Whoop callback reads its state from Redis, which isn't running in
  # CI. Both stubs only get the request far enough to prove the route matched.
  before do
    mock_owner_auth(email: "owner@example.com")
    allow($redis).to receive(:get).and_return(nil)
  end

  context "with API_HOST set" do
    around do |example|
      original = ENV["API_HOST"]
      ENV["API_HOST"] = api_host
      example.run
      ENV["API_HOST"] = original
    end

    owner_paths.each do |method, path|
      it "404s #{method.to_s.upcase} #{path} on the public API host" do
        process(method, "http://#{api_host}#{path}")

        expect(response).to have_http_status(:not_found)
      end

      it "keeps serving #{method.to_s.upcase} #{path} on the admin host" do
        process(method, "http://#{admin_host}#{path}")

        expect(response).not_to have_http_status(:not_found)
      end
    end

    public_paths.each do |method, path|
      it "keeps serving #{method.to_s.upcase} #{path} on the public API host" do
        process(method, "http://#{api_host}#{path}")

        expect(response).not_to have_http_status(:not_found)
      end
    end
  end

  # Unset is the dev, CI, and .fly.dev-origin case: every route is drawn on every host.
  context "with API_HOST unset" do
    around do |example|
      original = ENV["API_HOST"]
      ENV["API_HOST"] = nil
      example.run
      ENV["API_HOST"] = original
    end

    owner_paths.each do |method, path|
      it "serves #{method.to_s.upcase} #{path} on every host" do
        process(method, "http://#{api_host}#{path}")

        expect(response).not_to have_http_status(:not_found)
      end
    end
  end
end
