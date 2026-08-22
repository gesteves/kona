require "rails_helper"

RSpec.describe "Admin Bluesky connection", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    $redis.del(BlueskyCredentials::REDIS_KEY)
  end

  after { $redis.del(BlueskyCredentials::REDIS_KEY) }

  def sign_in! = sign_in_as(email: owner_email)

  describe "GET /connected-apps/bluesky" do
    before { sign_in! }

    it "renders the form" do
      get "/connected-apps/bluesky"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="handle"')
      expect(response.body).to include('name="app_password"')
    end

    # ⚠️ Use a Web Awesome component in place of a native element, as in each other admin page.
    it "uses Web Awesome controls rather than native ones" do
      get "/connected-apps/bluesky"

      expect(response.body).to include("<wa-input")
      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end

    it "never lets the page be stored" do
      get "/connected-apps/bluesky"

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    context "when a pair is already stored" do
      before { BlueskyCredentials.store(handle: "me.bsky.social", app_password: "super-secret-pw") }

      it "prefills the handle but never the password" do
        get "/connected-apps/bluesky"

        expect(response.body).to include("me.bsky.social")
        expect(response.body).not_to include("super-secret-pw")
      end

      it "says a password is saved" do
        get "/connected-apps/bluesky"

        expect(response.body).to include("A password is saved")
      end
    end

    context "when nothing is stored" do
      it "does not claim a password is saved" do
        get "/connected-apps/bluesky"

        expect(response.body).not_to include("A password is saved")
      end
    end
  end

  describe "POST /connected-apps/bluesky" do
    before { sign_in! }

    # ⚠️ The code checks the pair with a true session. An app password with a typing error, that the
    # code stores with no check, would make the sync fail at the next publish and give no
    # message.
    context "when the credentials open a session" do
      before { allow_any_instance_of(StandardSite).to receive(:create_session).and_return(true) }

      it "stores them and returns to the Connected apps page" do
        post "/connected-apps/bluesky", params: { handle: "me.bsky.social", app_password: "abcd-efgh" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/connected-apps")
        expect(flash[:notice]).to eq("Bluesky connected.")
        expect(BlueskyCredentials.fetch.handle).to eq("me.bsky.social")
        expect(BlueskyCredentials.fetch.app_password).to eq("abcd-efgh")
      end

      it "accepts a handle typed with a leading @" do
        post "/connected-apps/bluesky", params: { handle: "@me.bsky.social", app_password: "abcd-efgh" }

        expect(BlueskyCredentials.fetch.handle).to eq("me.bsky.social")
      end
    end

    context "when the credentials don't open a session" do
      before { allow_any_instance_of(StandardSite).to receive(:create_session).and_return(false) }

      it "stores nothing and re-renders the form with an error" do
        post "/connected-apps/bluesky", params: { handle: "me.bsky.social", app_password: "wrong" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("open a Bluesky session")
        expect(BlueskyCredentials.stored?).to be(false)
      end

      it "does not echo the rejected password back into the form" do
        post "/connected-apps/bluesky", params: { handle: "me.bsky.social", app_password: "rejected-pw" }

        expect(response.body).to include("me.bsky.social")
        expect(response.body).not_to include("rejected-pw")
      end
    end

    it "stores nothing when a field is missing" do
      post "/connected-apps/bluesky", params: { handle: "me.bsky.social", app_password: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(BlueskyCredentials.stored?).to be(false)
    end
  end

  describe "DELETE /connected-apps/bluesky" do
    before do
      sign_in!
      BlueskyCredentials.store(handle: "me.bsky.social", app_password: "abcd-efgh")
    end

    it "forgets the stored pair and returns to the page" do
      delete "/connected-apps/bluesky"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq("Bluesky disconnected.")
      expect(BlueskyCredentials.stored?).to be(false)
    end

    # ⚠️ The DID is public data and not a credential, and GET /api/standard-site supplies the
    # verification <link> tags on each page of the static site.
    it "leaves the cached DID alone" do
      $redis.set(StandardSite::DID_CACHE_KEY, "did:plc:abc123")

      delete "/connected-apps/bluesky"

      expect($redis.get(StandardSite::DID_CACHE_KEY)).to eq("did:plc:abc123")
    ensure
      $redis.del(StandardSite::DID_CACHE_KEY)
    end
  end

  describe "without an owner session" do
    it "redirects the page to the login screen" do
      get "/connected-apps/bluesky"

      expect(response).to redirect_to("/signin")
    end

    it "refuses to store credentials" do
      post "/connected-apps/bluesky", params: { handle: "me.bsky.social", app_password: "abcd-efgh" }

      expect(response).to redirect_to("/signin")
      expect(BlueskyCredentials.stored?).to be(false)
    end

    it "refuses to disconnect" do
      BlueskyCredentials.store(handle: "me.bsky.social", app_password: "abcd-efgh")

      delete "/connected-apps/bluesky"

      expect(response).to redirect_to("/signin")
      expect(BlueskyCredentials.stored?).to be(true)
    end
  end
end
