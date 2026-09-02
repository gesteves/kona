require "rails_helper"
require "open3"

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

  # Each shape that a body can hold, and the Bluesky field of each mention. The browser and the
  # server must read the same tokens and write the same Bluesky text: the count on the page
  # measures that text.
  MENTION_DRAFTS = [
    { "text" => "Great ride with @tony.", "values" => { "tony" => "tony.bsky.social" } },
    { "text" => "cc @me@hachyderm.io", "values" => {} },
    { "text" => "cc @tony.bsky.social", "values" => {} },
    { "text" => "thanks @Tony.", "values" => { "tony" => "Anthony Edwards" } },
    { "text" => "that is @Tony's bike", "values" => {} },
    { "text" => "write to me@example.com", "values" => {} },
    { "text" => "see https://bsky.app/profile/@tony.bsky.social", "values" => {} },
    { "text" => "café@tony", "values" => { "tony" => "@tony.bsky.social" } },
    { "text" => "@ana and @ben", "values" => { "ana" => "ana.bsky.social", "ben" => "Ben @home" } },
    # ⚠️ A no-break space at the end. `trim()` takes it off and `String#strip` does not, thus the
    # two files name each character that a trim takes off.
    { "text" => "hi @tony", "values" => { "tony" => "tony.bsky.social\u00A0" } },
    { "text" => "hi @tony", "values" => { "tony" => " tony.bsky.social\t" } }
  ].freeze

  # ⚠️ Ruby reads \w as ASCII by default, exactly as a plain JavaScript RegExp does. Thus "café@tony"
  # gives a token in both, and the boundary of the pattern needs no note about the two languages.
  it "finds the same tokens as the browser, for each shape that a body can hold" do
    expected = {
      "Great ride with @tony."                        => [ "@tony" ],
      "cc @me@hachyderm.io"                           => [ "@me@hachyderm.io" ],
      "cc @tony.bsky.social"                          => [ "@tony.bsky.social" ],
      "thanks @Tony."                                 => [ "@Tony" ],
      "that is @Tony's bike"                          => [ "@Tony" ],
      "write to me@example.com"                       => [],
      "see https://bsky.app/profile/@tony.bsky.social" => [],
      "café@tony"                                     => [ "@tony" ],
      "@ana and @ben"                                 => [ "@ana", "@ben" ]
    }
    expected.each do |text, tokens|
      expect(SocialMentions.tokens(text)).to eq(tokens),
        "Ruby reads #{text.inspect} as #{SocialMentions.tokens(text).inspect} and not #{tokens.inspect}."
    end
  end

  # ⚠️ This RUNS the browser file, as the markdown and typography contracts do. A comparison of
  # the patterns alone cannot see a difference in the skip of a URL, in the trim of a field, or in
  # the words that replace a token.
  it "reads the same tokens and writes the same Bluesky text as the browser" do
    node = `command -v node 2>/dev/null`.strip.presence
    skip "node is not on the PATH; `npm run build` needs it as well." if node.nil?

    from_js = run_javascript(node, js_path)

    MENTION_DRAFTS.each_with_index do |draft, index|
      tokens = SocialMentions.tokens(draft["text"])
      text = SocialMentions.substitute(draft["text"], values: draft["values"], network: "bluesky")

      expect(from_js[index]).to eq({ "tokens" => tokens, "text" => text }),
        "The two files read #{draft.inspect} differently. Ruby gives #{tokens.inspect} and " \
        "#{text.inspect}; the browser gives #{from_js[index].inspect}."
    end
  end

  # Runs the browser file over MENTION_DRAFTS. It copies the file to a **.mjs**, because
  # `package.json` has no `"type": "module"`.
  # @return [Array<Hash>]
  def run_javascript(node, js_path)
    Dir.mktmpdir do |dir|
      FileUtils.cp(js_path, File.join(dir, "social_mentions.mjs"))
      File.write(File.join(dir, "drafts.json"), JSON.generate(MENTION_DRAFTS))
      File.write(File.join(dir, "run.mjs"), <<~JS)
        import { readFileSync } from "node:fs";
        import { blueskyText, tokensOf } from "./social_mentions.mjs";

        const drafts = JSON.parse(readFileSync(new URL("./drafts.json", import.meta.url), "utf8"));
        const answers = drafts.map((d) => ({ tokens: tokensOf(d.text), text: blueskyText(d.text, d.values) }));
        process.stdout.write(JSON.stringify(answers));
      JS

      out, err, status = Open3.capture3(node, File.join(dir, "run.mjs"))
      raise "node could not run #{js_path.basename}: #{err}" unless status.success?

      JSON.parse(out)
    end
  end
end
