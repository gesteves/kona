require 'spec_helper'
require 'ostruct'

RSpec.describe CspHelpers do
  include MemoizationHelpers

  def plausible_event_path = '/pa/event'

  let(:articles) do
    [
      OpenStruct.new(body: '<iframe src="https://www.youtube-nocookie.com/embed/x"></iframe>', intro: nil),
      OpenStruct.new(body: '<blockquote></blockquote><script async src="https://embed.bsky.app/static/embed.js"></script>',
                     intro: '<iframe src="//open.spotify.com/embed/x"></iframe>')
    ]
  end
  let(:pages) { [ OpenStruct.new(body: '<iframe src="https://www.youtube.com/embed/y"></iframe><iframe src="about:blank"></iframe>', intro: nil) ] }

  def data = OpenStruct.new(articles: articles, pages: pages)

  it 'collects the frame and the script origins of each body, and a script host is also a frame host' do
    expect(embed_origins).to eq(
      frame: %w[https://embed.bsky.app https://open.spotify.com https://www.youtube-nocookie.com https://www.youtube.com],
      script: %w[https://embed.bsky.app]
    )
  end

  it 'starts each list with the hosts that every page needs' do
    expect(csp_frame_src.first).to eq('https://challenges.cloudflare.com')
    expect(csp_script_src.first(3)).to eq([ "'self'", plausible_init_script_hash, 'https://challenges.cloudflare.com' ])
    expect(csp_script_src).to include('https://embed.bsky.app')
    expect(csp_script_src).not_to include("'unsafe-inline'")
  end

  it 'names the hash of the exact inline script' do
    digest = Digest::SHA256.base64digest(plausible_init_script)
    expect(plausible_init_script_hash).to eq("'sha256-#{digest}'")
    expect(plausible_init_script).to include("endpoint: '/pa/event'")
  end
end
