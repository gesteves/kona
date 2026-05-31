require "rails_helper"

RSpec.describe TextHelper do
  subject(:helper) { Class.new { include TextHelper }.new }

  describe "#remove_widows" do
    it "joins the last two words with a non-breaking space" do
      expect(helper.remove_widows("one two three")).to eq("one two&nbsp;three")
    end

    it "leaves a single word alone" do
      expect(helper.remove_widows("single")).to eq("single")
    end

    it "returns nil for blank input" do
      expect(helper.remove_widows(nil)).to be_nil
      expect(helper.remove_widows("")).to be_nil
    end
  end

  describe "#comma_join_with_and" do
    it { expect(helper.comma_join_with_and(%w[a])).to eq("a") }
    it { expect(helper.comma_join_with_and(%w[a b])).to eq("a, and b") }
    it { expect(helper.comma_join_with_and(%w[a b c])).to eq("a, b, and c") }
    it { expect(helper.comma_join_with_and(%w[a b], false)).to eq("a and b") }
    it { expect(helper.comma_join_with_and(%w[a b c], false)).to eq("a, b and c") }
  end

  describe "#with_indefinite_article" do
    it { expect(helper.with_indefinite_article("apple")).to eq("an apple") }
    it { expect(helper.with_indefinite_article("banana")).to eq("a banana") }
    it { expect(helper.with_indefinite_article("8-ball")).to eq("an 8-ball") }
    it { expect(helper.with_indefinite_article("11th")).to eq("an 11th") }
    it { expect(helper.with_indefinite_article("18th")).to eq("an 18th") }
  end
end
