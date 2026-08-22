require "rails_helper"

RSpec.describe "Admin spam quarantine", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:quarantine) { instance_double(SpamQuarantine) }

  let(:message) do
    {
      "id" => "abc123",
      "name" => "Ivan Petrov",
      "email" => "ivan@example.ru",
      "message" => "Your website is not ranking on Google.",
      "context" => { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Moscow", "country" => "RU" },
      "received_at" => "2026-08-12T14:03:00Z"
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    allow(SpamQuarantine).to receive(:new).and_return(quarantine)
    # Each admin page renders the nav, and the nav needs the count for the badge.
    allow(quarantine).to receive(:count).and_return(0)
  end

  def sign_in!
    sign_in_as(email: owner_email)
  end

  describe "GET /spam" do
    before { sign_in! }

    context "with a quarantined message" do
      before { allow(quarantine).to receive(:all).and_return([ message ]) }

      it "renders every field the notification email carries" do
        get "/spam"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Ivan Petrov")
        expect(response.body).to include("ivan@example.ru")
        expect(response.body).to include("Your website is not ranking on Google.")
        expect(response.body).to include("Moscow, RU")
        expect(response.body).to include("203.0.113.7")
        expect(response.body).to include("Mozilla/5.0")
        expect(response.body).to include("2026-08-12T14:03:00Z")
      end

      it "offers both actions as Web Awesome buttons in real forms" do
        get "/spam"

        expect(response.body).to match(%r{<form[^>]*action="/spam/abc123/not-spam"}m)
        expect(response.body).to match(%r{<form[^>]*action="/spam/abc123"}m)
        expect(response.body).to include('name="_method" value="delete"')
        expect(response.body).to include("<wa-button type=\"submit\"")
        # A plain <button> means that a button_to came back into the code. wa-button renders its own
        # button in a shadow root.
        expect(response.body).not_to include("<button")
      end

      it "puts Delete forever behind a confirmation dialog" do
        get "/spam"

        expect(response.body).to include('<wa-dialog id="spam-delete-abc123"')
        expect(response.body).to include('data-dialog="open spam-delete-abc123"')
        expect(response.body).to include('data-dialog="close"')
      end

      it "renders icons rather than escaping them into the page" do
        get "/spam"

        expect(response.body).to match(/<svg [^>]*class="stub-icon"/)
        expect(response.body).not_to include("&lt;svg")
      end

      it "shows a short message whole, with no disclosure" do
        get "/spam"

        expect(response.body).not_to include("<wa-details")
      end
    end

    it "hides a long message behind a disclosure" do
      allow(quarantine).to receive(:all).and_return([ message.merge("message" => "spam " * 200) ])

      get "/spam"

      expect(response.body).to include('<wa-details summary="Show full message"')
    end

    # ⚠️ These fields are the only input from an attacker that this app renders as HTML with no
    # change.
    it "escapes a message that tries to inject markup" do
      allow(quarantine).to receive(:all).and_return([
        message.merge("name" => "<script>alert(1)</script>", "message" => "<img src=x onerror=alert(2)>")
      ])

      get "/spam"

      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(response.body).not_to include("<img src=x onerror=alert(2)>")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(response.body).to include("&lt;img src=x onerror=alert(2)&gt;")
    end

    it "says so when the queue is empty" do
      allow(quarantine).to receive(:all).and_return([])

      get "/spam"

      expect(response.body).to include("Nothing flagged")
      expect(response.body).not_to include("<wa-dialog")
    end

    it "never lets an admin page be stored" do
      allow(quarantine).to receive(:all).and_return([])
      get "/spam"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end
  end

  describe "POST /spam/:id/not-spam" do
    before { sign_in! }

    it "releases the message back into the delivery pipeline" do
      allow(quarantine).to receive(:take).with("abc123").and_return(message)

      post "/spam/abc123/not-spam"

      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Ivan Petrov",
        "ivan@example.ru",
        "Your website is not ranking on Google.",
        # The first submission time goes with the message, thus the email does not give the time of
        # the release.
        hash_including("ip" => "203.0.113.7", "received_at" => "2026-08-12T14:03:00Z"),
        true
      )
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/spam")
      expect(flash[:notice]).to include("released")
    end

    # ⚠️ SpamQuarantine#take reads and deletes in one step, thus two submissions cannot send the
    # email two times.
    it "does nothing when the message is already gone" do
      allow(quarantine).to receive(:take).with("abc123").and_return(nil)

      post "/spam/abc123/not-spam"

      expect(ContactMailJob.jobs).to be_empty
      expect(response).to have_http_status(:see_other)
      expect(flash[:alert]).to include("no longer in the queue")
    end
  end

  describe "DELETE /spam/:id" do
    before { sign_in! }

    it "deletes the message without delivering it" do
      expect(quarantine).to receive(:delete).with("abc123")

      delete "/spam/abc123"

      expect(ContactMailJob.jobs).to be_empty
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/spam")
      expect(flash[:notice]).to eq("Message deleted.")
    end
  end

  describe "without an owner session" do
    it "redirects the page to the sign-in screen" do
      get "/spam"
      expect(response).to redirect_to("/signin")
    end

    it "refuses to release a message" do
      expect(quarantine).not_to receive(:take)

      post "/spam/abc123/not-spam"

      expect(response).to redirect_to("/signin")
      expect(ContactMailJob.jobs).to be_empty
    end

    it "refuses to delete a message" do
      expect(quarantine).not_to receive(:delete)

      delete "/spam/abc123"

      expect(response).to redirect_to("/signin")
    end
  end
end
