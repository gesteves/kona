require "rails_helper"

RSpec.describe "Owner sessions", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  describe "GET /signin" do
    it "renders the Google sign-in button" do
      get "/signin"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sign in with Google")
    end

    # The page renders through layouts/auth, thus it needs the esbuild output that Propshaft gives a
    # fingerprint. With no build, Propshaft raises MissingAssetError and gives no smaller result.
    # That is why CI must run `npm run build` before rspec.
    it "links the compiled admin bundle" do
      get "/signin"
      expect(response.body).to match(%r{/assets/admin-[0-9a-f]+\.css})
      expect(response.body).to match(%r{/assets/admin-[0-9a-f]+\.js})
    end

    # ⚠️ Turbo Drive cannot follow the cross-origin redirect to Google, thus the form must not use
    # it.
    it "opts the sign-in form out of Turbo" do
      get "/signin"
      expect(response.body).to include('data-turbo="false"')
    end

    # ⚠️ icon_svg returns a plain String, thus ERB escapes it without `raw`. You can see that
    # failure: the escaped markup goes into the button as text and makes the button a few thousand
    # pixels wide.
    it "renders the Google mark as markup rather than escaped text" do
      get "/signin"
      expect(response.body).to match(/<svg [^>]*class="stub-icon"/)
      expect(response.body).not_to include("&lt;svg")
    end

    # This is the one page for the owner that a visitor can reach with no session, thus it is the
    # one page that a crawler can reach. ⚠️ The header does more than the meta tag: robots.txt
    # refuses this host, thus a crawler never gets the page and never sees the tag, but a search
    # engine can still index the URL from an external link.
    it "tells crawlers not to index it, by header and by meta tag" do
      get "/signin"

      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.body).to include('<meta name="robots" content="noindex">')
    end

    # The page has the button only, on purpose: no heading and no other text.
    it "renders nothing but the sign-in button" do
      get "/signin"

      expect(response.body).not_to include("<h1")
      expect(response.body).not_to include("<p")
    end
  end

  describe "the OAuth callback" do
    it "signs in the owner (verified, matching email) and redirects to the admin home page" do
      sign_in_as(email: owner_email)
      expect(response).to redirect_to("/")
    end

    it "returns the owner to the page they were headed to before signing in" do
      get "/whoop/auth" # unauthenticated → stashes return_to, redirects to /signin
      expect(response).to redirect_to("/signin")

      sign_in_as(email: owner_email)
      expect(response).to redirect_to("/whoop/auth")
    end

    it "rejects a non-owner email with 403 and no session" do
      sign_in_as(email: "someone-else@example.com")
      expect(response).to have_http_status(:forbidden)

      get "/whoop/auth"
      expect(response).to redirect_to("/signin")
    end

    it "rejects an unverified email with 403" do
      sign_in_as(email: owner_email, verified: false)
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects when OWNER_EMAIL is not configured" do
      allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(nil)
      sign_in_as(email: owner_email)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /signout" do
    it "clears the owner session" do
      sign_in_as(email: owner_email)
      post "/signout"
      expect(response).to redirect_to("/signin")

      get "/whoop/auth"
      expect(response).to redirect_to("/signin")
    end
  end
end
