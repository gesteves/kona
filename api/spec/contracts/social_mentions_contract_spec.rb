require "rails_helper"

# The mention patterns are in Ruby and in JavaScript, and the character count depends on both.
#
# `SocialMentions` makes the text that each network gets, and the action refuses a draft whose
# **Bluesky** text is past 300. `app/javascript/lib/social_mentions.js` makes that same text in the
# browser, because the count must follow each keystroke. Thus a difference makes the count line lie:
# the page says that a draft fits, the action then refuses it, and the owner cannot see the reason.
#
# ⚠️ The patterns are STRINGS in both files, and not Regexp literals. An interpolated Ruby Regexp
# gives a source with `(?-mix:…)` in it, and JavaScript cannot parse that.
RSpec.describe "SocialMentions Ruby ↔ JavaScript contract" do
  js_path = Rails.root.join("app/javascript/lib/social_mentions.js")
  let(:javascript) { File.read(js_path) }

  # @param name [String] The name of an exported const.
  # @return [String, nil] Its value, with each escape of the JavaScript literal removed.
  def exported(javascript, name)
    literal = javascript[/export const #{name} = ("(?:[^"\\]|\\.)*");/, 1]
    JSON.parse(literal) if literal
  end

  {
    "TOKEN_SOURCE"  => -> { SocialMentions::TOKEN_SOURCE },
    "DOMAIN_SOURCE" => -> { SocialMentions::DOMAIN_SOURCE },
    "URL_SOURCE"    => -> { Bluesky::URL_PATTERN.source }
  }.each do |name, ruby|
    it "gives #{name} the same pattern in the two files" do
      from_js = exported(javascript, name)

      expect(from_js).to be_present, "#{js_path.basename} exports no #{name}."
      expect(from_js).to eq(ruby.call),
        "The browser counts with one pattern and the action substitutes with another. " \
        "Ruby has #{ruby.call.inspect} and the browser has #{from_js.inspect}."
    end
  end

  # ⚠️ Ruby reads \w as ASCII by default, exactly as a plain JavaScript RegExp does. Thus "café@tony"
  # gives a token in both, and the boundary of the pattern needs no note about the two languages.
  it "finds the same tokens as the browser, for each shape that a body can hold" do
    {
      "Great ride with @tony."                        => [ "@tony" ],
      "cc @me@hachyderm.io"                           => [ "@me@hachyderm.io" ],
      "cc @tony.bsky.social"                          => [ "@tony.bsky.social" ],
      "thanks @Tony."                                 => [ "@Tony" ],
      "that is @Tony's bike"                          => [ "@Tony" ],
      "write to me@example.com"                       => [],
      "see https://bsky.app/profile/@tony.bsky.social" => [],
      "café@tony"                                     => [ "@tony" ],
      "@ana and @ben"                                 => [ "@ana", "@ben" ]
    }.each do |text, expected|
      expect(SocialMentions.tokens(text)).to eq(expected),
        "Ruby reads #{text.inspect} as #{SocialMentions.tokens(text).inspect}. " \
        "The browser must read it as #{expected.inspect}; refer to the table in this spec."
    end
  end
end
