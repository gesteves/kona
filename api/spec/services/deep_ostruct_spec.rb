require "rails_helper"

RSpec.describe DeepOstruct do
  it "wraps a hash for dot access" do
    obj = described_class.wrap(a: 1, b: "x")
    expect(obj.a).to eq(1)
    expect(obj.b).to eq("x")
  end

  it "wraps nested hashes recursively" do
    obj = described_class.wrap(sys: { id: "abc" })
    expect(obj.sys.id).to eq("abc")
  end

  it "wraps arrays of hashes" do
    obj = described_class.wrap([{ id: 1 }, { id: 2 }])
    expect(obj.map(&:id)).to eq([1, 2])
  end

  it "wraps hashes nested inside arrays inside hashes" do
    obj = described_class.wrap(items: [{ name: "a" }])
    expect(obj.items.first.name).to eq("a")
  end

  it "passes scalars through unchanged" do
    expect(described_class.wrap(5)).to eq(5)
    expect(described_class.wrap("s")).to eq("s")
    expect(described_class.wrap(nil)).to be_nil
  end

  it "returns nil for missing keys" do
    expect(described_class.wrap(a: 1).b).to be_nil
  end
end
