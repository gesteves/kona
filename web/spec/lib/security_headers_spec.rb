require 'spec_helper'
require 'json'

# The `/*` block of source/headers.erb and withSecurityHeaders in src/headers.ts must send the same
# headers. test/fixtures/security_headers.json is the one list, and test/headers.test.ts compares
# the Worker side with it.
RSpec.describe 'the security headers of the asset layer' do
  let(:fixture) { JSON.parse(File.read(File.expand_path('../../test/fixtures/security_headers.json', __dir__))) }

  # The headers of the `/*` block, with lower-case names. The CSP is not in the fixture: it
  # describes a document, and the Worker routes serve fragments and images.
  let(:asset_layer_headers) do
    lines = File.read(File.expand_path('../../source/headers.erb', __dir__)).lines
    block = lines.drop_while { |line| line.strip != '/*' }.drop(1).take_while { |line| line.strip != '' }
    block.reject { |line| line.strip.start_with?('#') }
         .to_h { |line| name, value = line.strip.split(': ', 2); [ name.downcase, value ] }
         .except('content-security-policy-report-only', 'content-security-policy')
  end

  it 'is the same list as the Worker sends' do
    expect(asset_layer_headers).to eq(fixture)
  end
end
