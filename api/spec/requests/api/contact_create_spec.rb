require "rails_helper"

RSpec.describe "Contact", type: :request do
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
    # Default Turnstile to unconfigured so these specs don't depend on a local .env having
    # TURNSTILE_SECRET; the "Turnstile verification" block stubs Turnstile#verify directly.
    allow(ENV).to receive(:[]).with("TURNSTILE_SECRET").and_return(nil)
  end

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
        { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0" }
      )
    end

    it "forwards the visitor geo into the job context" do
      post "/api/contact", params: valid_params, headers: json.merge(
        "X-Kona-Client-IP" => "203.0.113.7", "X-Kona-Client-City" => "Boise",
        "X-Kona-Client-Region" => "Idaho", "X-Kona-Client-Country" => "US"
      )

      expect(ContactMailJob).to have_enqueued_sidekiq_job(
        "Jane Rider", "jane@example.com", "Hello there!",
        { "ip" => "203.0.113.7", "city" => "Boise", "region" => "Idaho", "country" => "US" }
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
      expect(ContactMailJob).to have_enqueued_sidekiq_job("Jane Rider", "jane@example.com", "Hello there!", {})
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

  # Rails rejects these while building the params hash, so the request never reaches the action
  # and the response is a framework 400 rather than either of the paths above. The report it
  # would otherwise raise is dropped by ContactBadRequestFilter.
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
