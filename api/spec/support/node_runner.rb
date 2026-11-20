require "open3"
require "tmpdir"

# Runs a file of app/javascript/lib under node, for a contract spec that compares the browser code
# with its Ruby copy.
module NodeRunner
  LIB = Rails.root.join("app/javascript/lib")

  # @return [String, nil] The path of node, or nil where it is absent.
  def which_node
    `command -v node 2>/dev/null`.strip.presence
  end

  # Gives the drafts to a JavaScript expression and reads its answer.
  #
  # ⚠️ It copies each file to **.mjs**, because `package.json` has no `"type": "module"`. Node reads
  # a plain `.js` as CommonJS, and the `export` of those files is then a syntax error.
  # ⚠️ **An import specifier needs the extension written in.** esbuild resolves `./social_mentions`
  # and node does NOT, thus the copy changes each relative import to its `.mjs` name. Name each
  # file that the first one imports in `libs` as well.
  # @param node [String] The path of node.
  # @param libs [Array<String>] The names of the files to copy, with no extension.
  # @param drafts [Array] The input. The script reads it as `drafts`.
  # @param imports [String] The import lines of the script, from `./<name>.mjs`.
  # @param answer [String] A JavaScript expression over `drafts`. Its value comes back through JSON.
  # @return [Object] The value of the expression.
  def run_javascript(node, libs:, drafts:, imports:, answer:)
    Dir.mktmpdir do |dir|
      libs.each do |name|
        source = LIB.join("#{name}.js").read.gsub(%r{(?<=from ")\./(\w+)(?=")}, './\1.mjs')
        File.write(File.join(dir, "#{name}.mjs"), source)
      end
      File.write(File.join(dir, "drafts.json"), JSON.generate(drafts))
      File.write(File.join(dir, "run.mjs"), <<~JS)
        import { readFileSync } from "node:fs";
        #{imports}

        const drafts = JSON.parse(readFileSync(new URL("./drafts.json", import.meta.url), "utf8"));
        process.stdout.write(JSON.stringify(#{answer}));
      JS

      out, err, status = Open3.capture3(node, File.join(dir, "run.mjs"))
      raise "node could not run #{libs.first}.js: #{err}" unless status.success?

      JSON.parse(out)
    end
  end
end

RSpec.configure do |config|
  config.include NodeRunner
end
