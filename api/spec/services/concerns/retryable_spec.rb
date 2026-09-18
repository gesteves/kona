require "rails_helper"

RSpec.describe Retryable do
  let(:host) { Class.new { include Retryable }.new }

  before { allow(host).to receive(:sleep) }

  it "gives the value of the block after a failure that a later attempt corrects" do
    attempts = 0

    value = host.with_retries(max: 2) { attempts += 1; raise "boom" if attempts < 2; "ok" }

    expect(value).to eq("ok")
    expect(attempts).to eq(2)
  end

  it "raises the last error after the attempts end" do
    attempts = 0

    expect { host.with_retries(max: 2, base_delay: 1) { attempts += 1; raise "boom #{attempts}" } }.to raise_error("boom 3")
    expect(host).to have_received(:sleep).with(1).ordered
    expect(host).to have_received(:sleep).with(2).ordered
  end

  # ⚠️ An attempt does not occur if its wait would end after the deadline.
  it "stops at the deadline and does not start an attempt that cannot end in time" do
    clock = [ 0, 5 ]
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.shift || clock.last }
    attempts = 0

    expect { host.with_retries(max: 3, base_delay: 2, deadline: 6) { attempts += 1; raise "boom" } }.to raise_error("boom")
    expect(attempts).to eq(1)
    expect(host).not_to have_received(:sleep)
  end

  it "raises at once for an error outside the list" do
    attempts = 0

    expect { host.with_retries(max: 3, on: [ IOError ]) { attempts += 1; raise ArgumentError, "bad" } }.to raise_error(ArgumentError)
    expect(attempts).to eq(1)
  end
end
