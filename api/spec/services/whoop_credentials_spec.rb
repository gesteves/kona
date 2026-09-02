require "rails_helper"

RSpec.describe WhoopCredentials do
  it "seals a token so that Redis never holds it in the clear, and opens it again" do
    sealed = described_class.seal("a-refresh-token")
    expect(sealed).not_to include("a-refresh-token")
    expect(described_class.open(sealed)).to eq("a-refresh-token")
  end

  it "gives nil, and does not raise, for a value that it cannot read" do
    expect(described_class.open("not-a-message")).to be_nil
    expect(described_class.open(nil)).to be_nil
  end
end
