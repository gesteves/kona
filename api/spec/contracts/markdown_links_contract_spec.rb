require "rails_helper"
require "open3"

# The Markdown link grammar is in Ruby and in JavaScript, and the composer depends on both.
#
# `MarkdownLinks` makes the text that Bluesky receives, and the action refuses a draft whose text is
# past 300 or that posts a link to a network with no rich text.
# `app/javascript/lib/markdown_links.js` reads the same draft in the browser, because the count must
# follow each keystroke and the two checkboxes must go off at the keystroke that makes the first
# link.
#
# ⚠️ **A difference does NOT fail safe here**, and that is the difference from the mention contract.
# A browser that renders a link that Ruby does not shows a count that is too small, and the action
# then refuses a draft that the page called correct. A browser that finds no link where Ruby finds
# one leaves Mastodon and Threads ticked, and the action then refuses the submit.
#
# ⚠️ Thus this spec does not compare the patterns alone: it RUNS the JavaScript over the same drafts
# and compares the answers. The grammar is an algorithm and not one regular expression, and equal
# patterns prove very little about it.
RSpec.describe "MarkdownLinks Ruby ↔ JavaScript contract" do
  js_path = Rails.root.join("app/javascript/lib/markdown_links.js")
  let(:javascript) { File.read(js_path) }

  # @param name [String] The name of an exported const.
  # @return [String, nil] Its value, with each escape of the JavaScript literal removed.
  def exported(javascript, name)
    literal = javascript[/export const #{name} = ("(?:[^"\\]|\\.)*");/, 1]
    JSON.parse(literal) if literal
  end

  {
    "DEFINITION_SOURCE" => -> { MarkdownLinks::DEFINITION_SOURCE },
    "SPAN_SOURCE"       => -> { MarkdownLinks::SPAN_SOURCE },
    "URL_SOURCE"        => -> { MarkdownLinks::URL_SOURCE }
  }.each do |name, ruby|
    it "gives #{name} the same pattern in the two files" do
      from_js = exported(javascript, name)

      expect(from_js).to be_present, "#{js_path.basename} exports no #{name}."
      expect(from_js).to eq(ruby.call),
        "The browser reads a draft with one pattern and the action reads it with another. " \
        "Ruby has #{ruby.call.inspect} and the browser has #{from_js.inspect}."
    end
  end

  # Each shape that a draft can hold. ⚠️ Add a row here for each rule that you add to the grammar:
  # this table is the thing that keeps the two files together.
  MARKDOWN_DRAFTS = [
    "Read [my post](https://example.test/a) today",
    "Read [my post][a] today\n\n[a]: https://example.test/a",
    "See [kona] soon\n\n[kona]: https://example.test/k",
    "Collapsed [kona][] here\n\n[kona]: https://example.test/k",
    "I ate [a lot](really) today",
    "Bad ref [words][nope] stays",
    "That was [wild] today",
    "Plain words with no bracket at all",
    "[one](https://a.test) and [one](https://b.test)",
    "[a](https://x.test)[b](https://y.test)",
    "café [ünïcode](https://x.test) tail",
    "emoji 👨‍👩‍👧 [link](https://x.test)",
    "[](https://x.test) empty label",
    "[ ](https://x.test) label of one space",
    "[ ](https://x.test) label of one no-break space",
    "@tony wrote [this](https://example.test/@tony)",
    "Read https://example.test/a with no Markdown",
    "[ A ]: https://example.test/a\n\nsee [ a ]",
    "[x][A] and [y][a]\n\n[A]: https://example.test/1",
    "   [a]: https://example.test/a\nindent [a]",
    "    [a]: https://example.test/a\nfour spaces [a]",
    "line\r\n[a]: https://example.test/a\r\ncrlf [a]",
    "[a](https://x.test \"title\") the title form",
    "nested [a [b]](https://x.test)",
    "[multi\nline](https://x.test)",
    "[a](ftp://x.test) the wrong scheme",
    "[dup]: https://one.test\n[dup]: https://two.test\ntext [dup]",
    "trailing space [a](https://x.test) ",
    "A long day.\n\n[a]: https://example.test/a\n",
    "",
    "   "
  ].freeze

  # ⚠️ It compares the TEXT and the addresses, and not the offsets. The offsets of the browser are
  # UTF-16 code units and the offsets of Ruby are code points, thus the two differ by design for an
  # emoji. That is also why the browser file carries none: refer to the ⚠️ on `parse` there.
  it "reads each draft the same way as the browser" do
    node = which_node
    skip "node is not on the PATH; `npm run build` needs it as well." if node.nil?

    from_js = run_javascript(node, js_path)
    from_ruby = MARKDOWN_DRAFTS.map do |draft|
      result = MarkdownLinks.parse(draft)
      { "text" => result.text, "urls" => result.links.map(&:url) }
    end

    MARKDOWN_DRAFTS.each_with_index do |draft, index|
      expect(from_js[index]).to eq(from_ruby[index]),
        "The two files read #{draft.inspect} differently. " \
        "Ruby gives #{from_ruby[index].inspect} and the browser gives #{from_js[index].inspect}."
    end
  end

  # @return [String, nil] The path of node, or nil where it is absent.
  def which_node
    path = `command -v node 2>/dev/null`.strip
    path.presence
  end

  # Runs the browser file over MARKDOWN_DRAFTS.
  #
  # ⚠️ It copies the file to a **.mjs**, because `package.json` has no `"type": "module"`. Node
  # reads a plain `.js` as CommonJS, and the `export` of that file is then a syntax error.
  # @param node [String]
  # @param js_path [Pathname]
  # @return [Array<Hash>]
  def run_javascript(node, js_path)
    Dir.mktmpdir do |dir|
      module_path = File.join(dir, "markdown_links.mjs")
      FileUtils.cp(js_path, module_path)
      File.write(File.join(dir, "drafts.json"), JSON.generate(MARKDOWN_DRAFTS))
      File.write(File.join(dir, "run.mjs"), <<~JS)
        import { readFileSync } from "node:fs";
        import { parse } from "./markdown_links.mjs";

        const drafts = JSON.parse(readFileSync(new URL("./drafts.json", import.meta.url), "utf8"));
        const answers = drafts.map((draft) => {
          const result = parse(draft);
          return { text: result.text, urls: result.links.map((link) => link.url) };
        });
        process.stdout.write(JSON.stringify(answers));
      JS

      out, err, status = Open3.capture3(node, File.join(dir, "run.mjs"))
      raise "node could not run #{js_path.basename}: #{err}" unless status.success?

      JSON.parse(out)
    end
  end
end
