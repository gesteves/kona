require "rails_helper"

RSpec.describe "Admin home", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  # The variant and the words of each item of the toast stack.
  def toast_items
    stack = response.body[%r{<wa-toast\b.*?</wa-toast>}m].to_s

    stack.scan(%r{<wa-toast-item variant="([^"]+)">(.*?)</wa-toast-item>}m).map do |variant, message|
      [ variant, CGI.unescapeHTML(message) ]
    end
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

    # ⚠️ The fragment views have the data-live-update-* attributes. An admin page must never have
    # one, and no cache must hold an admin page.
    it "is never stored, never indexed, and carries no widget cache policy" do
      get "/"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end

    # The escape of ERB is the only thing between an attack in a contact submission and a script
    # that runs on the quarantine page, and that page is one click from an action that deletes data.
    # The CSP is the second layer.
    it "carries a Content-Security-Policy" do
      get "/"

      policy = response.headers["Content-Security-Policy-Report-Only"]
      expect(policy).to be_present
      expect(policy).to include("default-src 'self'")
      expect(policy).to include("frame-ancestors 'none'")
      expect(policy).to include("base-uri 'none'")
      # The location picker loads Mapbox GL JS from the CDN of Mapbox at run time.
      expect(policy).to include("https://api.mapbox.com")
    end

    # ⚠️ The nonce is what lets the inline dark-mode script run. Without it, the admin renders in the
    # light theme until the bundle loads, on each page, and a person would examine the CSP last.
    it "nonces the inline theme script rather than allowing inline script wholesale" do
      get "/"

      policy = response.headers["Content-Security-Policy-Report-Only"]
      nonce = policy[/'nonce-([^']+)'/, 1]
      expect(nonce).to be_present
      expect(response.body).to include(%(<script nonce="#{nonce}">))

      # ⚠️ script-src must not use unsafe-inline. style-src still needs it, because Web Awesome and
      # Mapbox both write styles at run time. That is why the nonce applies to script-src only.
      expect(policy[/script-src [^;]+/]).not_to include("'unsafe-inline'")
      expect(policy[/style-src [^;]+/]).to include("'unsafe-inline'")
    end

    # ⚠️ With no declaration, the browser keeps the last icon that it saw for this origin, which is
    # the icon of Sidekiq. Sidekiq::Web has one and it is on the same host.
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

    # ⚠️ Use a Web Awesome component in place of a native element wherever one exists. `button_to`
    # would write a native <button>. form_with with a <wa-button> that is part of the form keeps the
    # admin on one set of components. A plain <button> in the server HTML means that one came back:
    # wa-button renders its own button in a shadow root, thus no code here must have one.
    it "renders actions as Web Awesome buttons, not native ones" do
      get "/"

      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end
    it "opens Sidekiq in a new tab, and only Sidekiq" do
      get "/"

      # The test matches one attribute at a time, and not with one regex, because the order of the
      # attributes from Rails is not part of the contract.
      sidekiq_link = response.body.scan(/<wa-button\b[^>]*>/).find { |tag| tag.include?('href="/sidekiq"') }

      expect(sidekiq_link).to include('target="_blank"')
      expect(sidekiq_link).to include('rel="noopener"')
      expect(response.body).to include(I18n.t("admin.nav.new_tab"))
      # A link in the app must not have the external mark.
      expect(response.body.scan('target="_blank"').length).to eq(1)
    end

    # ⚠️ The flash is a TOAST and no longer a callout at the top of the page. It renders as a
    # <wa-toast-item> in the stack that the layout puts outside <wa-page>, and <wa-toast> starts the
    # timer of each item that its slot receives. Thus the server needs no code to show one.
    describe "the flash" do
      it "renders a notice as a success item of the toast stack" do
        delete "/connected-apps/bluesky"
        follow_redirect!

        expect(toast_items).to eq([ [ "success", I18n.t("admin.bluesky.flash.disconnected") ] ])
      end

      it "renders an alert as a danger item" do
        allow_any_instance_of(SpamQuarantine).to receive(:take).and_return(nil)
        allow_any_instance_of(SpamQuarantine).to receive(:all).and_return([])

        post "/spam/missing/not-spam"
        follow_redirect!

        expect(toast_items).to eq([ [ "danger", I18n.t("admin.spam_flash.gone") ] ])
      end

      it "renders an empty stack, and never a callout, when there is nothing to say" do
        get "/"

        expect(toast_items).to be_empty
        expect(response.body).to include("<wa-toast ")
        expect(response.body).not_to include("<wa-callout")
      end
    end

    describe "the Spam badge" do
      it "counts what's waiting in the spam quarantine" do
        allow_any_instance_of(SpamQuarantine).to receive(:count).and_return(3)

        get "/"

        expect(response.body).to match(
          %r{<wa-badge[^>]*>\s*3\s*<span class="wa-visually-hidden">#{Regexp.escape(I18n.t("admin.nav.waiting"))}</span>}m
        )
      end

      # A badge with a zero gives no information.
      it "is absent when the queue is empty" do
        allow_any_instance_of(SpamQuarantine).to receive(:count).and_return(0)

        get "/"

        expect(response.body).not_to include("<wa-badge")
      end
    end

    # <wa-page> moves one copy of the nav between the desktop sidebar and the mobile drawer. Thus a
    # second copy in the markup would appear two times on the desktop. Each link needs
    # data-drawer="close", or the drawer stays open over the page that the link goes to.
    it "writes the navigation once, with drawer-closing links" do
      get "/"

      expect(response.body.scan('slot="navigation"').length).to eq(1)
      expect(response.body).to include('data-drawer="close"')
    end

    # ⚠️ icon_svg returns a plain String, thus ERB escapes it without `raw`. The nav and the menu
    # button then show their SVG source as text.
    it "renders the nav and toggle icons as markup rather than escaped text" do
      get "/"

      expect(response.body).to match(/<svg [^>]*class="stub-icon"/)
      expect(response.body).not_to include("&lt;svg")
    end

    describe "the nav groups" do
      it "labels each group and points its list at that label" do
        get "/"

        # ⚠️ The id comes from the :key of the group, and NOT from the label. Thus a change to a
        # word cannot move an id, and this spec keeps the id as a literal.
        %w[tools settings more].each do |key|
          id = "admin-nav-#{key}"
          label = I18n.t("admin.nav.groups.#{key}")
          expect(response.body).to include(%(<div class="admin-nav__group-label wa-caption-s" id="#{id}">#{label}</div>))
          expect(response.body).to include(%(aria-labelledby="#{id}"))
        end
      end
    end
  end
end
