require "rails_helper"

# The typography runs on the server, and the character count runs in the browser.
#
# `Typography` writes the text that each network receives: curly quotation marks, an ellipsis, and
# the two dashes. `app/javascript/lib/typography.js` writes only the part of that which changes the
# LENGTH, because the count must follow each keystroke.
#
# ⚠️ **The two files do NOT give the same text, on purpose, and they must give the same LENGTH.**
# The browser leaves every quotation mark straight: `"` becomes `“` and `'` becomes `’`, and each of
# those is one character in place of one. Thus the direction of a quotation mark — the hard half of
# SmartyPants, and the half that no small copy could match — cannot change a count. What is left is
# the ellipsis and the two dashes, and each of those is context-free.
#
# ⚠️ A browser count that is too SMALL is the failure that matters: the page would call a draft
# correct and the action would then refuse it. This spec runs both files and compares the lengths.
RSpec.describe "Typography Ruby ↔ JavaScript contract" do
  # Each shape that changes a length, and each shape that must not.
  #
  # ⚠️ **No character above the BMP here**, and an emoji spec below covers that. Ruby counts code
  # points and JavaScript counts UTF-16 code units, thus only text where the two agree can compare
  # `.length` directly. Every rule of this file is ASCII punctuation, thus nothing is lost.
  TYPOGRAPHY_DRAFTS = [
    %q(It's a "big" day),
    %q(He said "she said 'no'" loudly),
    %q(5'10" tall),
    "Wait... really?",
    "a...b",
    "a....b",
    "a.....b",
    "a. . .b",
    "a.  .  .b",
    "A -- B and C --- D",
    "a--b",
    "a---b",
    "a----b",
    "a-----b",
    "a-b",
    "a - - b",
    "e.g. a.b.c",
    "1...2...3",
    "plain words with nothing to change",
    "",
    "See https://example.test/a--b now",
    "See https://example.test/a...b now",
    "a https://example.test/a--b b https://example.test/c...d e",
    %q(He said "see https://example.test/x now" loudly),
    %q{Read [my post](https://example.test/a--b) -- it's good},
    "Ref [a][x]... good\n\n[x]: https://example.test/a--b",
    "It's here: https://example.test/a--b... really",
    # ⚠️ The pattern takes each character up to a space, thus `.trim_url` is the thing that decides
    # where an address ends, and the two files must decide the same way.
    "Wiki https://en.wikipedia.org/wiki/Kona_(Hawaii)... nice",
    "An aside (see https://example.test/a--b)... ok",
    "Path https://example.test/\u65E5\u672C--a... ok",
    "Bracket https://example.test/a[b]--c... ok",
    "Copyright (c) 2026 (r) (tm)",
    "(C) (R) (TM)",
    "a 1/2 mile and 1/4 of a 3/4",
    "11/2 and 1/22 and 1/2/3",
    "https://example.test/(c)/1/2 and (c)",
    "cc @xn--80ak6aa92e.com now -- really",
    "@a--b.test and a--b",
    "see https://example.test/@x--y and @me@a--b.social"
  ].freeze

  it "shortens each draft to the same length as the browser" do
    node = which_node
    skip "node is not on the PATH; `npm run build` needs it as well." if node.nil?

    from_js = run_javascript(node, libs: %w[typography social_mentions], drafts: TYPOGRAPHY_DRAFTS,
                                   imports: 'import { applyLengthRules } from "./typography.mjs";',
                                   answer: "drafts.map((d) => applyLengthRules(d).length)")

    TYPOGRAPHY_DRAFTS.each_with_index do |draft, index|
      from_ruby = Typography.apply(draft)

      expect(from_js[index]).to eq(from_ruby.length),
        "The browser counts #{draft.inspect} as #{from_js[index]} characters and the server " \
        "posts #{from_ruby.inspect}, which is #{from_ruby.length}. A browser count that is too " \
        "small lets the page call a draft correct that the action then refuses."
    end
  end

  # ⚠️ An emoji is one grapheme at Bluesky, more than one code point in Ruby, and more than one
  # UTF-16 unit in the browser. The typography must not touch one at all, thus the count of the
  # whole post is the concern of `Bluesky.post_length` and of `social_post_controller.js`.
  it "changes no emoji" do
    expect(Typography.apply("Ride 🚴‍♂️ 👨‍👩‍👧")).to eq("Ride 🚴‍♂️ 👨‍👩‍👧")
  end
end
