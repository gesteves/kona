require "rails_helper"

RSpec.describe "Admin home", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "redirects to the login screen when signed out, remembering where we were headed" do
    get "/"

    expect(response).to redirect_to("/signin")

    sign_in_as(email: owner_email)
    expect(response).to redirect_to("/")
  end

  context "when signed in as the owner" do
    before { sign_in_as(email: owner_email) }

    it "renders the shell" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<wa-page")
      expect(response.body).to include('<h1 class="admin-main__title">Home</h1>')
    end

    # ⚠️ The fragment views are what carry data-live-update-*; an admin page must never grow one,
    # and must never be cacheable.
    it "is never stored, never indexed, and carries no widget cache policy" do
      get "/"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end

    # ⚠️ Without a declaration the browser keeps whatever it last saw for this origin, which is
    # Sidekiq's own icon — Sidekiq::Web ships one and mounts on the same host.
    it "declares its own favicon" do
      get "/"

      expect(response.body).to include('<link rel="icon" href="/favicon.ico"')
    end

    it "puts the site wordmark in the header, linking home" do
      get "/"

      expect(response.body).to include('class="admin-header__home"')
      expect(response.body).to include("741.59 202.81") # the logo's viewBox
      expect(response.body).not_to include("admin-header__title")
    end

    # ⚠️ Web Awesome components over native elements wherever one exists. `button_to` would emit a
    # native <button>; form_with + a form-associated <wa-button> keeps the admin on one component
    # vocabulary. A bare <button> in the server HTML means one slipped back in — wa-button renders
    # its own inside a shadow root, so nothing here should have one.
    it "renders actions as Web Awesome buttons, not native ones" do
      get "/"

      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end
    it "opens Sidekiq in a new tab, and only Sidekiq" do
      get "/"

      # Matched attribute-by-attribute rather than with one regex, since Rails' attribute order
      # isn't part of the contract.
      sidekiq_link = response.body.scan(/<a\b[^>]*>/).find { |tag| tag.include?('href="/sidekiq"') }

      expect(sidekiq_link).to include('target="_blank"')
      expect(sidekiq_link).to include('rel="noopener"')
      expect(response.body).to include("(opens in a new tab)")
      # The in-app links must not be marked external.
      expect(response.body.scan('target="_blank"').length).to eq(1)
    end

    describe "the Contact badge" do
      it "counts what's waiting in the spam quarantine" do
        allow_any_instance_of(SpamQuarantine).to receive(:count).and_return(3)

        get "/"

        expect(response.body).to match(%r{<wa-badge[^>]*>\s*3\s*<span class="wa-visually-hidden">waiting</span>}m)
      end

      # A zero badge is noise, not information.
      it "is absent when the queue is empty" do
        allow_any_instance_of(SpamQuarantine).to receive(:count).and_return(0)

        get "/"

        expect(response.body).not_to include("<wa-badge")
      end
    end

    # <wa-page> moves one copy of the nav between the desktop sidebar and the mobile drawer, so a
    # second authored copy would show twice on desktop. Links need data-drawer="close" or the
    # drawer stays open over the page they navigate to.
    it "writes the navigation once, with drawer-closing links" do
      get "/"

      expect(response.body.scan('slot="navigation"').length).to eq(1)
      expect(response.body).to include('data-drawer="close"')
    end

    # ⚠️ icon_svg returns a plain String, so ERB escapes it without `raw` — the nav and the
    # hamburger then render their SVG source as visible text.
    it "renders the nav and toggle icons as markup rather than escaped text" do
      get "/"

      expect(response.body).to match(/<svg [^>]*class="stub-icon"/)
      expect(response.body).not_to include("&lt;svg")
    end
  end
end
