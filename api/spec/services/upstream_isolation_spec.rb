require "rails_helper"

# The code behind the rule that a dependency that fails gives "no data" and not a 500. Each widget
# controller and most of the services use it, and no test covered it directly.
RSpec.describe UpstreamIsolation do
  let(:klass) do
    Class.new do
      include UpstreamIsolation
      def self.name = "FakeService"

      # `safely` is private. This makes it available to the spec, in the way that a true caller uses
      # it.
      def call(...) = safely(...)
    end
  end

  subject(:service) { klass.new }

  before { allow(ErrorReporter).to receive(:report_upstream) }

  it "returns the block's value when nothing raises" do
    expect(service.call { 42 }).to eq(42)
    expect(ErrorReporter).not_to have_received(:report_upstream)
  end

  it "returns nil by default when the block raises" do
    expect(service.call { raise "boom" }).to be_nil
  end

  it "returns the given fallback when the block raises" do
    expect(service.call("Upstream", []) { raise "boom" }).to eq([])
  end

  it "reports the failure under the given service label and context" do
    service.call("Whoop", nil, context: "stats") { raise ArgumentError, "bad" }

    expect(ErrorReporter).to have_received(:report_upstream)
      .with(instance_of(ArgumentError), hash_including(service: "Whoop", context: "stats"))
  end

  it "defaults the service label and context to the including class" do
    service.call { raise "boom" }

    expect(ErrorReporter).to have_received(:report_upstream)
      .with(instance_of(RuntimeError), hash_including(service: "FakeService", context: "FakeService"))
  end

  it "logs the failure" do
    allow(Rails.logger).to receive(:error)

    service.call(context: "fetching") { raise "boom" }

    expect(Rails.logger).to have_received(:error).with(/fetching: boom/)
  end

  # ⚠️ This catches a StandardError only. A Timeout, an Interrupt, and a SignalException must not
  # become an empty widget with no message, and a NoMemoryError on the 512MB worker must not
  # either.
  it "does not swallow errors outside StandardError" do
    expect { service.call { raise Exception, "fatal" } }.to raise_error(Exception, "fatal")
  end
end
