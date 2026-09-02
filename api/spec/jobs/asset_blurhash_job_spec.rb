require "rails_helper"

RSpec.describe AssetBlurhashJob do
  it "makes the placeholder of the asset" do
    placeholder = instance_double(BlurhashPlaceholder)
    allow(BlurhashPlaceholder).to receive(:new).and_return(placeholder)
    expect(placeholder).to receive(:generate).with("asset-1")

    described_class.new.perform("asset-1")
  end

  # ⚠️ The guide says that this job fails soft. A placeholder is an improvement, and a failure
  # must not put the job into the retry set for a day.
  it "does not raise when the placeholder cannot be made" do
    allow_any_instance_of(BlurhashPlaceholder).to receive(:generate!).and_raise(SocketError, "down")
    allow(ErrorReporter).to receive(:report_upstream)

    expect { described_class.new.perform("asset-1") }.not_to raise_error
    expect(ErrorReporter).to have_received(:report_upstream).with(kind_of(SocketError), hash_including(context: "blurhash placeholder asset-1"))
  end
end
