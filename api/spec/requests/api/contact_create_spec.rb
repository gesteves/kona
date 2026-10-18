require "rails_helper"

RSpec.describe "Contact", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:token) { "test-token" }
  let(:site_url) { "https://example.test" }
  let(:valid_params) { { name: "Jane Rider", email: "jane@example.com", message: "Hello there!" } }
  let(:auth) { { "Authorization" => "Bearer #{token}" } }
  let(:json) { auth.merge("Accept" => "application/json") }
  let(:html) { auth.merge("Accept" => "text/html") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
    allow(ENV).to receive(:[]).with("SITE_URL").and_return(site_url)
    # By default, Turnstile has no configuration. Thus these specs do not depend on a local .env with
    # TURNSTILE_SECRET in it. The "Turnstile verification" group stubs Turnstile#verify.
    allow(ENV).to receive(:[]).with("TURNSTILE_SECRET").and_return(nil)
    # No spec makes a real DNS query. The "Email domain" group changes this.
    allow(EmailDomain).to receive(:accepts_mail?).and_return(true)
  end

  # Api::ContactController records the arrival time when the Worker sends none.
  around { |example| travel_to(Time.utc(2026, 8, 1, 12, 0, 0)) { example.run } }

  describe "authentication" do
    it "rejects requests without a bearer token" do
      post "/api/contact", params: valid_params
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects requests with the wrong bearer token" do
      post "/api/contact", params: valid_params, headers: { "Authorization" => "Bearer nope" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "JSON submissions (the fetch path)" do
    it "enqueues a ContactMailJob and returns 204 for a valid submission" do
      post "/api/contact", params: valid_params,
        headers: json.merge("X-Kona-Client-IP" => "203.0.113.7", "X-Kona-Client-UA" => "Mozilla/5.0")

      expect(response).to have_http_status(:no_content)
      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Jane Rider", "jane@example.com", "Hello there!",
        { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "received_at" => "2026-08-01T12:00:00Z" }
      )
    end

    it "forwards the visitor geo, network, port, and edge time into the job context" do
      post "/api/contact", params: valid_params, headers: json.merge(
        "X-Kona-Client-IP" => "203.0.113.7", "X-Kona-Client-Port" => "54321",
        "X-Kona-Client-City" => "Boise", "X-Kona-Client-Region" => "Idaho",
        "X-Kona-Client-Country" => "US", "X-Kona-Client-Network" => "Comcast Cable",
        "X-Kona-Client-Time" => "2026-08-01T11:59:48.123Z"
      )

      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Jane Rider", "jane@example.com", "Hello there!",
        { "ip" => "203.0.113.7", "port" => "54321", "city" => "Boise", "region" => "Idaho",
          "country" => "US", "network" => "Comcast Cable", "received_at" => "2026-08-01T11:59:48Z" }
      )
    end

    it "uses its own clock when the edge time is not ISO 8601" do
      post "/api/contact", params: valid_params, headers: json.merge("X-Kona-Client-Time" => "soon")

      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Jane Rider", "jane@example.com", "Hello there!", { "received_at" => "2026-08-01T12:00:00Z" }
      )
    end

    it "returns 422 and does not enqueue when a field is missing" do
      post "/api/contact", params: valid_params.except(:message), headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "returns 422 for a malformed email" do
      post "/api/contact", params: valid_params.merge(email: "not-an-email"), headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "silently accepts (204) and drops honeypot submissions" do
      post "/api/contact", params: valid_params.merge(comment: "I am a bot"), headers: json
      expect(response).to have_http_status(:no_content)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "does not durably cache the response" do
      post "/api/contact", params: valid_params, headers: json
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "HTML submissions (the no-JS native form path)" do
    it "enqueues a ContactMailJob and redirects to the Thank-You page for a valid submission" do
      post "/api/contact", params: valid_params, headers: html

      expect(response).to redirect_to("#{site_url}/contact/success")
      expect(response).to have_http_status(:see_other)
      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Jane Rider", "jane@example.com", "Hello there!", { "received_at" => "2026-08-01T12:00:00Z" }
      )
    end

    it "silently redirects to the Thank-You page and drops honeypot submissions" do
      post "/api/contact", params: valid_params.merge(comment: "I am a bot"), headers: html

      expect(response).to redirect_to("#{site_url}/contact/success")
      expect(ContactMailJob.jobs).to be_empty
    end

    it "redirects back to the form when a field is missing" do
      post "/api/contact", params: valid_params.except(:name), headers: html

      expect(response).to redirect_to("#{site_url}/contact")
      expect(ContactMailJob.jobs).to be_empty
    end
  end

  describe "length caps" do
    it "rejects an over-long message" do
      post "/api/contact", params: valid_params.merge(message: "x" * 5001), headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "rejects an over-long name" do
      post "/api/contact", params: valid_params.merge(name: "x" * 101), headers: json
      expect(response).to have_http_status(:unprocessable_content)
      expect(ContactMailJob.jobs).to be_empty
    end
  end

  # Rails refuses each of these while it makes the params hash. Thus the request never reaches the
  # action, and the response is a 400 from the framework and not one of the two answers above.
  # ContactBadRequestFilter removes the report that Rails would send.
  describe "a body that isn't valid UTF-8" do
    let(:form) { { "CONTENT_TYPE" => "application/x-www-form-urlencoded" } }
    let(:body) { "name=Jane+Rider&email=jane%40example.com&message=%FF%FE" }

    it "rejects the submission on the JSON path without enqueuing" do
      post "/api/contact", params: body, headers: json.merge(form)

      expect(response).to have_http_status(:bad_request)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "rejects the submission on the no-JS HTML path without enqueuing" do
      post "/api/contact", params: body, headers: html.merge(form)

      expect(response).to have_http_status(:bad_request)
      expect(ContactMailJob.jobs).to be_empty
    end
  end

  describe "Email domain" do
    it "returns 422 with its own message and does not enqueue for a domain that can't receive mail" do
      allow(EmailDomain).to receive(:accepts_mail?).with("jane@gmail.con").and_return(false)

      post "/api/contact", params: valid_params.merge(email: "jane@gmail.con"), headers: json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq(Api::ContactController::UNDELIVERABLE_EMAIL)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "redirects back to the form on the no-JS path for a domain that can't receive mail" do
      allow(EmailDomain).to receive(:accepts_mail?).and_return(false)

      post "/api/contact", params: valid_params, headers: html

      expect(response).to redirect_to("#{site_url}/contact")
      expect(ContactMailJob.jobs).to be_empty
    end

    # ⚠️ The check fails closed: the visitor sends again, and no message skips it.
    it "returns 503 and does not enqueue when the lookup times out" do
      allow(EmailDomain).to receive(:accepts_mail?).and_raise(EmailDomain::LookupError)

      post "/api/contact", params: valid_params, headers: json

      expect(response).to have_http_status(:service_unavailable)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "redirects back to the form on the no-JS path when the lookup times out" do
      allow(EmailDomain).to receive(:accepts_mail?).and_raise(EmailDomain::LookupError)

      post "/api/contact", params: valid_params, headers: html

      expect(response).to redirect_to("#{site_url}/contact")
      expect(ContactMailJob.jobs).to be_empty
    end

    it "does no lookup for a request that fails Turnstile" do
      allow_any_instance_of(Turnstile).to receive(:verify).and_return(false)

      post "/api/contact", params: valid_params.merge("cf-turnstile-response" => "bad"), headers: json

      expect(EmailDomain).not_to have_received(:accepts_mail?)
    end
  end

  describe "Turnstile verification" do
    it "rejects a JSON submission whose Turnstile token fails" do
      allow_any_instance_of(Turnstile).to receive(:verify).and_return(false)

      post "/api/contact", params: valid_params.merge("cf-turnstile-response" => "bad"), headers: json

      expect(response).to have_http_status(:unprocessable_content)
      expect(ContactMailJob.jobs).to be_empty
    end

    it "accepts a JSON submission whose Turnstile token passes" do
      allow_any_instance_of(Turnstile).to receive(:verify).and_return(true)

      post "/api/contact", params: valid_params.merge("cf-turnstile-response" => "good"), headers: json

      expect(response).to have_http_status(:no_content)
    end

    it "skips Turnstile on the no-JS HTML path" do
      expect_any_instance_of(Turnstile).not_to receive(:verify)

      post "/api/contact", params: valid_params, headers: html

      expect(response).to have_http_status(:see_other)
    end
  end
end
