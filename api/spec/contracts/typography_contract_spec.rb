require "rails_helper"
require "open3"

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
  js_path = Rails.root.join("app/javascript/lib/typography.js")

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

    from_js = run_javascript(node, js_path)

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

  # @return [String, nil] The path of node, or nil where it is absent.
  def which_node
    `command -v node 2>/dev/null`.strip.presence
  end

  # Runs the browser file over TYPOGRAPHY_DRAFTS and gives the length of each answer.
  #
  # ⚠️ It copies the two files to **.mjs**, because `package.json` has no `"type": "module"`. Node
  # reads a plain `.js` as CommonJS, and the `export` of those files is then a syntax error.
  # @return [Array<Integer>]
  def run_javascript(node, js_path)
    Dir.mktmpdir do |dir|
      # ⚠️ typography.js imports URL_SOURCE from social_mentions.js, thus the copy needs that file
      # as well. ⚠️ **The import specifier needs the extension written in.** esbuild resolves
      # `./social_mentions` and node does NOT: an ESM import there must name the file exactly.
      File.write(File.join(dir, "typography.mjs"),
                 File.read(js_path).gsub(%r{(?<=from ")\./social_mentions(?=")},
                                         "./social_mentions.mjs"))
      FileUtils.cp(Rails.root.join("app/javascript/lib/social_mentions.js"),
                   File.join(dir, "social_mentions.mjs"))
      File.write(File.join(dir, "drafts.json"), JSON.generate(TYPOGRAPHY_DRAFTS))
      File.write(File.join(dir, "run.mjs"), <<~JS)
        import { readFileSync } from "node:fs";
        import { applyLengthRules } from "./typography.mjs";

        const drafts = JSON.parse(readFileSync(new URL("./drafts.json", import.meta.url), "utf8"));
        process.stdout.write(JSON.stringify(drafts.map((d) => applyLengthRules(d).length)));
      JS

      out, err, status = Open3.capture3(node, File.join(dir, "run.mjs"))
      raise "node could not run #{js_path.basename}: #{err}" unless status.success?

      JSON.parse(out)
    end
  end
end
