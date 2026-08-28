require "rails_helper"

# The public API hostname serves only /up and the three machine namespaces. Rails draws each route
# for the owner behind the `API_HOST` constraint in config/routes.rb.
#
# ⚠️ That constraint is what makes the bot-protection skip rule of the zone ("skip each host but the
# admin one") safe. A route for the owner that a visitor can reach on the public host would be there
# with the managed rules and Super Bot Fight Mode off, and nothing in the zone would find it.
RSpec.describe "Public API host route constraints", type: :request do
  api_host = "api.example.test"
  admin_host = "admin.example.test"

  owner_paths = [
    [ :get,  "/whoop/auth" ],
    [ :get,  "/whoop/callback" ],
    [ :get,  "/signin" ],
    [ :post, "/signout" ],
    [ :get,  "/auth/google_oauth2/callback" ],
    [ :get,  "/auth/failure" ],
    [ :get,  "/sidekiq" ],
    [ :get,  "/connected-apps" ],
    [ :delete, "/connected-apps/whoop" ],
    [ :get,  "/connected-apps/bluesky" ],
    [ :post, "/connected-apps/bluesky" ],
    [ :delete, "/connected-apps/bluesky" ],
    [ :get,  "/connected-apps/mastodon" ],
    [ :post, "/connected-apps/mastodon" ],
    [ :delete, "/connected-apps/mastodon" ],
    [ :get,  "/connected-apps/mastodon/callback" ],
    [ :get,  "/location" ],
    [ :get,  "/location/lookup" ],
    [ :post, "/location" ],
    [ :get,  "/spam" ],
    [ :post, "/spam/abc123/not-spam" ],
    [ :delete, "/spam/abc123" ],
    [ :get,  "/course-maps" ],
    [ :post, "/course-maps" ],
    [ :get,  "/course-maps/status" ],
    [ :get,  "/course-maps/abc123" ],
    [ :patch, "/course-maps/abc123" ],
    [ :delete, "/course-maps/abc123" ],
    [ :get,  "/course-maps/abc123/preview" ],
    [ :get,  "/course-maps/abc123/download" ]
  ]

  # One path for each namespace that the public host must continue to answer. Most of them need a
  # bearer token or an HMAC and give a 401 here, and that is correct: each status but a 404 shows
  # that the route still exists.
  public_paths = [
    [ :get,  "/up" ],
    [ :get,  "/widgets/whoop" ],
    [ :get,  "/widgets/articles/trending" ],
    [ :get,  "/api/standard-site" ],
    [ :post, "/api/build" ],
    [ :post, "/webhooks/contentful" ],
    [ :get,  "/" ]
  ]

  # The two paths that reach the body of a controller and not a check: the OmniAuth callback needs a
  # test auth hash, and the Whoop callback reads its state from Redis, which does not run in CI. Each
  # stub takes the request only far enough to show that the route matched.
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

    # `/` is the one path where the two hosts give a different answer, and where neither one gives a
    # 404. The admin UI is at the root of the admin host, and the public host keeps the redirect to
    # the main site. Rails draws two routes for "/", thus only their order and the host constraint
    # keep them apart, and a change to the order would break that with no message.
    it "serves the owner home page at / on the admin host" do
      process(:get, "http://#{admin_host}/")

      expect(response).to redirect_to("/signin") # owner-gated, so unauthenticated lands here
    end

    it "still redirects / to the main site on the public API host" do
      process(:get, "http://#{api_host}/")

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["location"]).not_to include("/signin")
    end
  end

  # With no value, which is the condition in development, in CI, and on the .fly.dev origin, Rails
  # draws each route on each host.
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
