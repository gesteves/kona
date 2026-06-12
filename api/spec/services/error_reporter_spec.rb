require "rails_helper"

RSpec.describe ErrorReporter do
  describe ".report_upstream" do
    # A stand-in for the Bugsnag::Report yielded to the notify block.
    let(:report) { double("Bugsnag::Report", :severity= => nil, add_metadata: nil) }

    it "notifies Bugsnag at warning severity with the upstream metadata" do
      allow(Bugsnag).to receive(:notify) { |_exception, &block| block.call(report) }

      described_class.report_upstream(
        ArgumentError.new("nope"),
        service: "Whoop", context: "token refresh", status: 401, url: "https://x.test/y?key=secret"
      )

      expect(report).to have_received(:severity=).with("warning")
      expect(report).to have_received(:add_metadata).with(
        :upstream,
        { service: "Whoop", context: "token refresh", status: 401, url: "https://x.test/y" }
      )
    end

    it "passes an exception through to Bugsnag unchanged" do
      error = ArgumentError.new("nope")
      expect(Bugsnag).to receive(:notify).with(error)
      described_class.report_upstream(error, service: "Whoop")
    end

    it "wraps a non-exception message in an UpstreamError" do
      expect(Bugsnag).to receive(:notify).with(an_instance_of(ErrorReporter::UpstreamError)) do |exception|
        expect(exception.message).to eq("HTTP 500")
      end
      described_class.report_upstream("HTTP 500", service: "WeatherKit")
    end

    it "omits nil metadata fields so only what's known is reported" do
      allow(Bugsnag).to receive(:notify) { |_exception, &block| block.call(report) }
      described_class.report_upstream("HTTP 503", service: "Goodspeed")
      expect(report).to have_received(:add_metadata).with(:upstream, { service: "Goodspeed" })
    end

    it "never raises into the caller when Bugsnag itself fails" do
      allow(Bugsnag).to receive(:notify).and_raise("bugsnag unavailable")
      expect(Rails.logger).to receive(:error).with(/ErrorReporter/)
      expect { described_class.report_upstream("HTTP 500", service: "X") }.not_to raise_error
    end
  end

  describe ".sanitize_url" do
    it "drops the query string so credentials are never reported" do
      expect(described_class.sanitize_url("https://maps.googleapis.com/geo/json?key=SECRET&latlng=1,2"))
        .to eq("https://maps.googleapis.com/geo/json")
    end

    it "keeps the scheme, host, and path" do
      expect(described_class.sanitize_url("https://api.example.test/v1/widgets"))
        .to eq("https://api.example.test/v1/widgets")
    end

    it "returns nil for a blank url" do
      expect(described_class.sanitize_url(nil)).to be_nil
      expect(described_class.sanitize_url("")).to be_nil
    end

    it "returns nil for an unparseable url instead of raising" do
      expect(described_class.sanitize_url("http://exa mple.test/bad")).to be_nil
    end
  end
end
