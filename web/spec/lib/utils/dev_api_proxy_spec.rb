require 'spec_helper'
require_relative '../../../lib/utils/dev_api_proxy'

RSpec.describe DevApiProxy do
  # It records each value that it gets, thus a test can check that the request went through with no
  # change.
  let(:inner) { ->(env) { [ 200, { 'content-type' => 'text/html' }, [ "page:#{env['PATH_INFO']}" ] ] } }
  let(:proxy) { described_class.new(inner) }

  # A small replacement for an HTTParty::Response: the middleware reads these three values only.
  def upstream(code: 200, body: '', headers: {})
    instance_double(HTTParty::Response, code: code, body: body, headers: headers)
  end

  def env_for(path, method: 'GET', **overrides)
    {
      'PATH_INFO' => path,
      'REQUEST_METHOD' => method,
      'rack.input' => StringIO.new('')
    }.merge(overrides)
  end

  around do |example|
    original = ENV.values_at('KONA_API_URL', 'API_TOKEN')
    ENV['KONA_API_URL'] = 'http://localhost:3000'
    ENV['API_TOKEN'] = 'test-token'
    example.run
    ENV['KONA_API_URL'], ENV['API_TOKEN'] = original
  end

  describe 'paths it does not claim' do
    it 'passes a page request to the inner app' do
      expect(HTTParty).not_to receive(:get)
      status, _headers, body = proxy.call(env_for('/2026/06/26/a-post/'))

      expect(status).to eq(200)
      expect(body).to eq([ 'page:/2026/06/26/a-post/' ])
    end

    it 'passes /pa/* through, so local page views never reach Plausible' do
      expect(HTTParty).not_to receive(:get)
      _status, _headers, body = proxy.call(env_for('/pa/event'))

      expect(body).to eq([ 'page:/pa/event' ])
    end

    it 'passes a non-POST /api/contact through' do
      expect(HTTParty).not_to receive(:post)
      _status, _headers, body = proxy.call(env_for('/api/contact'))

      expect(body).to eq([ 'page:/api/contact' ])
    end
  end

  describe 'widgets' do
    it 'forwards to KONA_API_URL with the bearer injected' do
      expect(HTTParty).to receive(:get).with(
        'http://localhost:3000/widgets/activity-stats',
        hash_including(headers: { 'authorization' => 'Bearer test-token' })
      ).and_return(upstream(body: '<div>stats</div>', headers: { 'content-type' => 'text/html' }))

      status, headers, body = proxy.call(env_for('/widgets/activity-stats'))

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/html')
      expect(body).to eq([ '<div>stats</div>' ])
    end

    it 'passes an empty 200 through, so the widget still collapses' do
      allow(HTTParty).to receive(:get).and_return(upstream(body: ''))

      status, _headers, body = proxy.call(env_for('/widgets/whoop'))

      expect(status).to eq(200)
      expect(body).to eq([ '' ])
    end

    it 'passes a non-2xx through rather than rewriting it' do
      allow(HTTParty).to receive(:get).and_return(upstream(code: 401, body: ''))

      status, = proxy.call(env_for('/widgets/whoop'))

      expect(status).to eq(401)
    end

    it 'answers an unreachable api with an empty 502' do
      allow(HTTParty).to receive(:get).and_raise(Errno::ECONNREFUSED)

      status, _headers, body = proxy.call(env_for('/widgets/whoop'))

      expect(status).to eq(502)
      expect(body).to eq([ '' ])
    end

    it 'answers an unset KONA_API_URL with an empty 502 rather than raising' do
      ENV['KONA_API_URL'] = ''
      expect(HTTParty).not_to receive(:get)

      status, _headers, body = proxy.call(env_for('/widgets/whoop'))

      expect(status).to eq(502)
      expect(body).to eq([ '' ])
    end
  end

  describe 'the contact form' do
    it 'forwards the body and the visitor signal the api scores spam on' do
      expect(HTTParty).to receive(:post).with(
        'http://localhost:3000/api/contact',
        hash_including(
          body: 'name=Ada',
          headers: hash_including(
            'authorization' => 'Bearer test-token',
            'accept' => 'application/json',
            'x-kona-client-ip' => '203.0.113.7',
            'x-kona-client-ua' => 'Firefox'
          )
        )
      ).and_return(upstream(code: 204))

      status, = proxy.call(env_for(
        '/api/contact',
        method: 'POST',
        'rack.input' => StringIO.new('name=Ada'),
        'HTTP_ACCEPT' => 'application/json',
        'REMOTE_ADDR' => '203.0.113.7',
        'HTTP_USER_AGENT' => 'Firefox'
      ))

      expect(status).to eq(204)
    end

    it 'passes the no-JS 303 and its Location through' do
      allow(HTTParty).to receive(:post)
        .and_return(upstream(code: 303, headers: { 'location' => '/contact/success/' }))

      status, headers, = proxy.call(env_for('/api/contact', method: 'POST'))

      expect(status).to eq(303)
      expect(headers['location']).to eq('/contact/success/')
    end
  end
end
