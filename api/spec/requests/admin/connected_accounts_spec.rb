require "rails_helper"

RSpec.describe "Admin connected accounts", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  def sign_in!
    sign_in_as(email: owner_email)
  end

  describe "GET /connected-accounts" do
    before { sign_in! }

    context "when Whoop is not configured" do
      before { allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false) }

      it "reports it as unconfigured and offers no action" do
        get "/connected-accounts"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Not configured")
        expect(response.body).not_to include("/whoop/auth")
      end
    end

    context "when Whoop is configured but no account is attached" do
      before do
        allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:connected?).and_return(false)
      end

      it "offers a Connect link that opts out of Turbo" do
        get "/connected-accounts"

        expect(response.body).to include("Not connected")
        expect(response.body).to include("/whoop/auth")
        # ⚠️ /whoop/auth is same-origin but 302s to Whoop, which Turbo Drive can't follow.
        expect(response.body).to include('data-turbo="false"')
      end
    end

    context "when Whoop is connected" do
      before do
        allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(true)
        allow_any_instance_of(Whoop).to receive(:connected?).and_return(true)
      end

      it "offers Disconnect instead of Connect" do
        get "/connected-accounts"

        expect(response.body).to include("Connected")
        expect(response.body).to include("Disconnect")
        expect(response.body).not_to include("/whoop/auth")
      end

      # ⚠️ Web Awesome components over native elements. A bare <button> means a `button_to` crept
      # back in — wa-button renders its own inside a shadow root.
      it "renders Disconnect as a Web Awesome button in a real form" do
        get "/connected-accounts"

        expect(response.body).to match(%r{<form[^>]*action="/connected-accounts/whoop"}m)
        expect(response.body).to include('name="_method" value="delete"')
        expect(response.body).to include("<wa-button type=\"submit\"")
        expect(response.body).not_to include("<button")
      end
    end

    it "never lets an admin page be stored" do
      allow_any_instance_of(Whoop).to receive(:valid_credentials?).and_return(false)
      get "/connected-accounts"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end
  end

  describe "DELETE /connected-accounts/whoop" do
    before { sign_in! }

    it "forgets the stored credentials and returns to the page" do
      expect_any_instance_of(Whoop).to receive(:disconnect!)

      delete "/connected-accounts/whoop"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-accounts")
      expect(flash[:notice]).to eq("Whoop disconnected.")
    end
  end

  describe "without an owner session" do
    it "redirects the page to the login screen" do
      get "/connected-accounts"
      expect(response).to redirect_to("/signin")
    end

    it "refuses the disconnect action" do
      expect_any_instance_of(Whoop).not_to receive(:disconnect!)

      delete "/connected-accounts/whoop"

      expect(response).to redirect_to("/signin")
    end
  end
end
