require "rails_helper"

RSpec.describe MarkdownHelper do
  subject(:helper) { Class.new { include MarkdownHelper }.new }

  describe "#markdown_to_html" do
    it "renders Markdown bold as <strong>" do
      expect(helper.markdown_to_html("**bold**")).to eq("<p><strong>bold</strong></p>\n")
    end

    it "applies SmartyPants typography (curly apostrophe entity)" do
      expect(helper.markdown_to_html("it's")).to include("it&rsquo;s")
    end

    it "returns nil for blank input" do
      expect(helper.markdown_to_html(nil)).to be_nil
      expect(helper.markdown_to_html("")).to be_nil
    end
  end

  describe "#smartypants" do
    it "curls quotes and apostrophes" do
      expect(helper.smartypants(%(don't))).to include("don&rsquo;t")
    end

    it "returns nil for blank input" do
      expect(helper.smartypants(nil)).to be_nil
    end
  end
end
