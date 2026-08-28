require "rails_helper"

RSpec.describe "Admin connected apps", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    # Bluesky and Mastodon each have their own card on this page. Remove their credentials, thus
    # the Whoop examples do not depend on the credentials that are available.
    $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY)
  end

  after { $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY) }

  def sign_in!
    sign_in_as(email: owner_email)
  end

  describe "GET /connected-apps" do
    before { sign_in! }

    context "when Whoop is not configured" do
      before { allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false) }

      it "reports it as unconfigured and offers no action" do
        get "/connected-apps"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Not configured")
        expect(response.body).not_to include("/whoop/auth")
      end
    end

    context "when Whoop is configured but nothing is attached" do
      before do
        allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:connected?).and_return(false)
      end

      it "offers a Connect link that opts out of Turbo" do
        get "/connected-apps"

        expect(response.body).to include("Not connected")
        expect(response.body).to include("/whoop/auth")
        # ⚠️ /whoop/auth is same-origin, but it gives a 302 to Whoop, and Turbo Drive cannot
        # follow that.
        expect(response.body).to include('data-turbo="false"')
      end
    end

    context "when Whoop is connected" do
      before do
        allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:connected?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:refresh_error).and_return(nil)
      end

      it "offers Disconnect instead of Connect" do
        get "/connected-apps"

        expect(response.body).to include("Connected")
        expect(response.body).to include("Disconnect")
        expect(response.body).not_to include("/whoop/auth")
      end

      # ⚠️ Use a Web Awesome component in place of a native element. A plain <button> means that a
      # `button_to` came back into the code: wa-button renders its own button in a shadow root.
      it "renders Disconnect as a Web Awesome button in a real form" do
        get "/connected-apps"

        expect(response.body).to match(%r{<form[^>]*action="/connected-apps/whoop"}m)
        expect(response.body).to include('name="_method" value="delete"')
        expect(response.body).to include("<wa-button type=\"submit\"")
        expect(response.body).not_to include("<button")
      end
    end

    # ⚠️ Whoop keeps its tokens in Redis after it refuses them, thus connected? cannot see the
    # difference between this state and the state above. Without the record of the failure, the page
    # shows a green badge while the widget and the Intervals.icu sync do not work.
    context "when Whoop is connected but its refresh token has been rejected" do
      before do
        allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:connected?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:refresh_error)
          .and_return(code: 401, at: "2026-08-18T22:00:00Z")
      end

      it "flags it and says what went wrong" do
        get "/connected-apps"

        expect(response.body).to include("Needs attention")
        expect(response.body).to include("HTTP 401")
        expect(response.body).to include("August 18, 2026")
      end

      it "offers Reconnect alongside Disconnect, so the fix doesn't need a disconnect first" do
        get "/connected-apps"

        expect(response.body).to include("Reconnect")
        expect(response.body).to include("/whoop/auth")
        expect(response.body).to include("Disconnect")
      end
    end

    it "never lets an admin page be stored" do
      allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false)
      get "/connected-apps"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end
  end

  describe "the Bluesky card" do
    before do
      sign_in!
      allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false)
    end

    it "offers a link to the credentials form when nothing is attached" do
      get "/connected-apps"

      expect(response.body).to include("Bluesky")
      expect(response.body).to include("/connected-apps/bluesky")
    end

    context "when credentials are stored" do
      before { BlueskyCredentials.store(handle: "me.bsky.social", app_password: "abcd-efgh") }

      it "reports it as connected and offers Disconnect" do
        get "/connected-apps"

        expect(response.body).to include("Connected")
        expect(response.body).to match(%r{<form[^>]*action="/connected-apps/bluesky"}m)
        expect(response.body).to include('name="_method" value="delete"')
      end

      it "never renders the stored password" do
        get "/connected-apps"

        expect(response.body).not_to include("abcd-efgh")
      end
    end
  end

  describe "the Mastodon card" do
    before do
      sign_in!
      allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false)
    end

    it "offers a link to the instance form when no account is attached" do
      get "/connected-apps"

      expect(response.body).to include("Mastodon")
      expect(response.body).to include("/connected-apps/mastodon")
      expect(response.body).to include("Not connected")
    end

    context "when an account is connected" do
      before do
        MastodonCredentials.store_client(
          instance: "mastodon.social", client_id: "id", client_secret: "secret",
          redirect_uri: "http://www.example.com/connected-apps/mastodon/callback"
        )
        MastodonCredentials.store_token(access_token: "tok-en", handle: "@me@mastodon.social")
      end

      it "names the account and offers Disconnect" do
        get "/connected-apps"

        expect(response.body).to include("@me@mastodon.social")
        expect(response.body).to match(%r{<form[^>]*action="/connected-apps/mastodon"}m)
        expect(response.body).to include('name="_method" value="delete"')
      end

      it "never renders the stored token" do
        get "/connected-apps"

        expect(response.body).not_to include("tok-en")
      end
    end
  end

  describe "DELETE /connected-apps/whoop" do
    before { sign_in! }

    it "forgets the stored credentials and returns to the page" do
      expect_any_instance_of(Whoop).to receive(:disconnect!)

      delete "/connected-apps/whoop"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq("Whoop disconnected.")
    end
  end

  describe "without an owner session" do
    it "redirects the page to the login screen" do
      get "/connected-apps"
      expect(response).to redirect_to("/signin")
    end

    it "refuses the disconnect action" do
      expect_any_instance_of(Whoop).not_to receive(:disconnect!)

      delete "/connected-apps/whoop"

      expect(response).to redirect_to("/signin")
    end
  end
end
