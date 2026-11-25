require 'spec_helper'
require 'rake'
require 'tmpdir'

# build_site renames the two Cloudflare files after the Middleman build. ⚠️ A build with no
# _redirects or _headers would deploy with no redirect and no security header, thus it must stop.
RSpec.describe 'build_site' do
  include Rake::FileUtilsExt

  before(:all) do
    load File.expand_path('../../../lib/tasks/build.rake', __dir__) unless Object.private_method_defined?(:build_site)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(BUILD_DIRECTORY)
        example.run
      end
    end
  end

  before { allow(self).to receive(:sh) }

  def make_build_files(*names)
    names.each { |name| File.write(File.join(BUILD_DIRECTORY, name), "#{name}\n") }
  end

  it 'renames redirects and headers for Cloudflare, then runs Pagefind' do
    make_build_files('redirects', 'headers')

    build_site

    expect(File.read(File.join(BUILD_DIRECTORY, '_redirects'))).to eq("redirects\n")
    expect(File.read(File.join(BUILD_DIRECTORY, '_headers'))).to eq("headers\n")
    expect(self).to have_received(:sh).with('middleman build').ordered
    expect(self).to have_received(:sh).with('npm run pagefind').ordered
  end

  it 'runs the verbose build when asked' do
    make_build_files('redirects', 'headers')

    build_site(verbose: true)

    expect(self).to have_received(:sh).with('middleman build --verbose')
  end

  %w[redirects headers].each do |missing|
    it "stops, and runs no Pagefind, when the build made no #{missing}" do
      make_build_files(*(%w[redirects headers] - [ missing ]))

      expect { build_site }.to raise_error(RuntimeError, %r{source/#{missing}\.erb did not render})
      expect(self).not_to have_received(:sh).with('npm run pagefind')
    end
  end
end
