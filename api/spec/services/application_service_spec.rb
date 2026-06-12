require "rails_helper"

RSpec.describe ApplicationService do
  # A tiny subclass that exposes the protected/private helpers for testing.
  let(:service_class) do
    Class.new(ApplicationService) do
      def cache(*args, **kwargs, &block) = cached_json(*args, **kwargs, &block)
      def http_get(*args, **kwargs) = get_json(*args, **kwargs)
      def http_post(*args, **kwargs) = post_json(*args, **kwargs)
      def underscore(obj) = underscore_keys(obj)
      def retrying(...) = with_retries(...)
      def guarded(*args, **kwargs, &block) = rescue_with(*args, **kwargs, &block)
    end
  end
  let(:service) { service_class.new }

  def response_double(success:, body:, code: 200, url: "https://example.test/path")
    request = instance_double(HTTParty::Request, last_uri: URI.parse(url))
    instance_double(HTTParty::Response, success?: success, body: body, code: code, request: request)
  end

  describe "#cached_json" do
    it "returns the parsed cached value without yielding when the key is populated" do
      allow($redis).to receive(:get).with("k").and_return('{"a":1}')

      yielded = false
      result = service.cache("k") { yielded = true; { a: 99 } }

      expect(result).to eq(a: 1)
      expect(yielded).to be(false)
    end

    it "parses cached values with string keys when symbolize: false" do
      allow($redis).to receive(:get).with("k").and_return('{"a":1}')
      expect(service.cache("k", symbolize: false) { {} }).to eq("a" => 1)
    end

    it "yields, caches with a TTL, and returns the value on a miss" do
      allow($redis).to receive(:get).with("k").and_return(nil)
      expect($redis).to receive(:setex).with("k", 5.minutes, '{"a":1}')

      expect(service.cache("k", expires_in: 5.minutes) { { a: 1 } }).to eq(a: 1)
    end

    it "does not cache when no TTL is given (never caches indefinitely)" do
      allow($redis).to receive(:get).with("k").and_return(nil)
      expect($redis).not_to receive(:setex)
      expect($redis).not_to receive(:set)

      expect(service.cache("k") { { a: 1 } }).to eq(a: 1)
    end

    it "does not cache when the TTL is zero or falsey" do
      allow($redis).to receive(:get).with("k").and_return(nil)
      expect($redis).not_to receive(:setex)
      expect($redis).not_to receive(:set)

      expect(service.cache("k", expires_in: 0) { { a: 1 } }).to eq(a: 1)
      expect(service.cache("k", expires_in: false) { { a: 1 } }).to eq(a: 1)
    end

    it "does not cache a blank value" do
      allow($redis).to receive(:get).with("k").and_return(nil)
      expect($redis).not_to receive(:setex)
      expect($redis).not_to receive(:set)

      expect(service.cache("k", expires_in: 5.minutes) { nil }).to be_nil
    end

    it "bypasses the cache entirely in development (always fetches fresh)" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      expect($redis).not_to receive(:get)
      expect($redis).not_to receive(:setex)
      expect($redis).not_to receive(:set)

      calls = 0
      result = service.cache("k", expires_in: 5.minutes) { calls += 1; { a: calls } }
      expect(result).to eq(a: 1)
      expect(service.cache("k", expires_in: 5.minutes) { calls += 1; { a: calls } }).to eq(a: 2)
    end
  end

  describe "#get_json / #post_json" do
    it "returns the parsed body on success" do
      allow(HTTParty).to receive(:get).and_return(response_double(success: true, body: '{"a":1}'))
      expect(service.http_get("https://example.test")).to eq(a: 1)
    end

    it "returns nil on a non-success response" do
      allow(HTTParty).to receive(:get).and_return(response_double(success: false, body: "nope"))
      expect(service.http_get("https://example.test")).to be_nil
    end

    it "reports a non-success response to Bugsnag with its status code and url" do
      allow(HTTParty).to receive(:get)
        .and_return(response_double(success: false, body: "nope", code: 429, url: "https://upstream.test/data?key=secret"))
      message, kwargs = nil
      allow(ErrorReporter).to receive(:report_upstream) { |msg, **kw| message = msg; kwargs = kw }

      expect(service.http_get("https://upstream.test/data")).to be_nil
      expect(message).to eq("HTTP 429")
      expect(kwargs).to include(status: 429, url: "https://upstream.test/data?key=secret")
    end

    it "does not report a successful response" do
      allow(HTTParty).to receive(:get).and_return(response_double(success: true, body: '{"a":1}'))
      expect(ErrorReporter).not_to receive(:report_upstream)
      service.http_get("https://example.test")
    end

    it "posts and parses with string keys when symbolize: false" do
      allow(HTTParty).to receive(:post).and_return(response_double(success: true, body: '{"a":1}'))
      expect(service.http_post("https://example.test", symbolize: false)).to eq("a" => 1)
    end
  end

  describe "#underscore_keys" do
    it "rewrites camelCase keys to snake_case symbols, recursively" do
      expect(service.underscore({ "timeZoneId" => { "shortName" => "MST" } }))
        .to eq(time_zone_id: { short_name: "MST" })
    end

    it "returns nil for nil" do
      expect(service.underscore(nil)).to be_nil
    end
  end

  describe "#with_retries" do
    before { allow(service).to receive(:sleep) }

    it "returns the block value without retrying on success" do
      calls = 0
      expect(service.retrying { calls += 1; "ok" }).to eq("ok")
      expect(calls).to eq(1)
    end

    it "retries on error and returns nil once exhausted" do
      calls = 0
      result = service.retrying(max: 2) { calls += 1; raise "boom" }
      expect(result).to be_nil
      expect(calls).to eq(3) # initial + 2 retries
    end

    it "reports the error to Bugsnag once, only after the retries are exhausted" do
      reported = nil
      allow(ErrorReporter).to receive(:report_upstream) { |err, **| reported = err }
      service.retrying(max: 2) { raise "boom" }
      expect(ErrorReporter).to have_received(:report_upstream).once
      expect(reported).to be_a(RuntimeError).and have_attributes(message: "boom")
    end

    it "does not report when the block eventually succeeds" do
      expect(ErrorReporter).not_to receive(:report_upstream)
      attempts = 0
      result = service.retrying(max: 2) { attempts += 1; raise "boom" if attempts < 2; "ok" }
      expect(result).to eq("ok")
    end
  end

  describe "#rescue_with" do
    it "returns the block value when it succeeds" do
      expect(service.guarded { "ok" }).to eq("ok")
    end

    it "logs and returns the fallback when the block raises" do
      expect(Rails.logger).to receive(:error).with(/boom/)
      expect(service.guarded([], context: "ctx") { raise "boom" }).to eq([])
    end

    it "reports the error to Bugsnag in addition to logging" do
      allow(Rails.logger).to receive(:error)
      reported = nil
      context = nil
      allow(ErrorReporter).to receive(:report_upstream) { |err, **kw| reported = err; context = kw[:context] }

      service.guarded([], context: "ctx") { raise "boom" }
      expect(reported).to be_a(RuntimeError).and have_attributes(message: "boom")
      expect(context).to eq("ctx")
    end
  end
end
