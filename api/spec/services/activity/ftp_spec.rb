require "rails_helper"

RSpec.describe Ftp do
  describe ".parse" do
    it "gives whole watts" do
      expect(described_class.parse("265")).to eq(265)
      expect(described_class.parse(265)).to eq(265)
      expect(described_class.parse("264.6")).to eq(265)
    end

    it "gives nil for text or a value out of range" do
      expect(described_class.parse("abc")).to be_nil
      expect(described_class.parse("Infinity")).to be_nil
      expect(described_class.parse("10")).to be_nil
      expect(described_class.parse("2650")).to be_nil
    end
  end
end
