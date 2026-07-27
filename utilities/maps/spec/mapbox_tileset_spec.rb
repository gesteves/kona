require 'spec_helper'
require_relative '../lib/mapbox_tileset'

RSpec.describe MapboxTileset do
  def uploader
    described_class.new(username: 'testuser', token: 'sk.test-token')
  end

  def response_double(body: nil, code: 200, success: true)
    double('HTTParty::Response', body: body, code: code, success?: success)
  end

  describe '#initialize' do
    it 'raises when the username is missing' do
      expect {
        described_class.new(username: nil, token: 'sk.test-token')
      }.to raise_error('Mapbox username is missing! Set MAPBOX_USERNAME.')
      expect {
        described_class.new(username: '', token: 'sk.test-token')
      }.to raise_error('Mapbox username is missing! Set MAPBOX_USERNAME.')
    end

    it 'raises when the token is missing' do
      expect {
        described_class.new(username: 'testuser', token: nil)
      }.to raise_error('Mapbox secret token is missing! Set MAPBOX_SECRET_TOKEN.')
    end
  end

  describe '#sanitize_name' do
    it 'transliterates accents to ASCII' do
      expect(uploader.send(:sanitize_name, 'São Paulo Marathon')).to eq('Sao Paulo Marathon')
      expect(uploader.send(:sanitize_name, 'Cañón José')).to eq('Canon Jose')
    end

    it 'drops curly apostrophes and other characters outside the Mapbox-allowed set' do
      # transliterate turns the curly quote into "?", which the character filter removes.
      expect(uploader.send(:sanitize_name, 'Ironman Coeur d’Alene 70.3')).to eq('Ironman Coeur dAlene 70.3')
    end

    it 'keeps allowed punctuation (dash, underscore, period) and collapses whitespace' do
      expect(uploader.send(:sanitize_name, "Race! @Boulder   (2024)")).to eq('Race Boulder 2024')
      expect(uploader.send(:sanitize_name, 'a-b_c.d')).to eq('a-b_c.d')
    end

    it 'caps the result at 64 characters' do
      expect(uploader.send(:sanitize_name, 'a' * 70)).to eq('a' * 64)
    end

    it 'returns an empty string for nil' do
      expect(uploader.send(:sanitize_name, nil)).to eq('')
    end
  end

  describe '#parsed_message' do
    it 'extracts the message from a JSON error body' do
      response = response_double(body: '{"message":"Invalid recipe"}')
      expect(uploader.send(:parsed_message, response)).to eq('Invalid recipe')
    end

    it 'returns nil when the body is not JSON' do
      response = response_double(body: '<html>Internal Server Error</html>')
      expect(uploader.send(:parsed_message, response)).to be_nil
    end

    it 'returns nil when the body is nil' do
      response = response_double(body: nil)
      expect(uploader.send(:parsed_message, response)).to be_nil
    end

    it 'returns nil when the JSON is not an object (indexing raises TypeError)' do
      response = response_double(body: '["not", "a", "hash"]')
      expect(uploader.send(:parsed_message, response)).to be_nil
    end
  end

  describe '#upload_error' do
    it 'includes the action and the parsed message' do
      response = response_double(body: '{"message":"Invalid recipe"}', code: 400)
      expect(uploader.send(:upload_error, 'create tileset', response))
        .to eq('Mapbox failed to create tileset: Invalid recipe')
    end

    it 'falls back to the status code when the body has no message' do
      response = response_double(body: 'nope', code: 422)
      expect(uploader.send(:upload_error, 'publish tileset', response))
        .to eq('Mapbox failed to publish tileset: status 422')
    end

    it 'falls back to the status code when the message is empty' do
      response = response_double(body: '{"message":""}', code: 500)
      expect(uploader.send(:upload_error, 'upload tileset source', response))
        .to eq('Mapbox failed to upload tileset source: status 500')
    end
  end

  describe '#already_exists?' do
    it 'is true when the error message says the tileset already exists' do
      response = response_double(body: '{"message":"testuser.abc already exists"}', code: 400)
      expect(uploader.send(:already_exists?, response)).to be(true)
    end

    it 'matches case-insensitively' do
      response = response_double(body: '{"message":"Tileset Already Exists."}', code: 400)
      expect(uploader.send(:already_exists?, response)).to be(true)
    end

    it 'is false for other error messages' do
      response = response_double(body: '{"message":"Invalid recipe"}', code: 400)
      expect(uploader.send(:already_exists?, response)).to be(false)
    end

    it 'is false when the body is not JSON' do
      response = response_double(body: 'already exists', code: 400)
      # The plain-text body mentions "already exists" but parsed_message only reads
      # JSON, so this does not count — pins that the check is strictly JSON-based.
      expect(uploader.send(:already_exists?, response)).to be(false)
    end
  end

  describe '#find' do
    it 'returns the full tileset id and its first vector layer when published' do
      response = response_double(
        body: '{"vector_layers":[{"id":"track"},{"id":"other"}]}',
        success: true
      )
      allow(HTTParty).to receive(:get).and_return(response)

      expect(uploader.find('morning_run_4e481c66')).to eq(['testuser.morning_run_4e481c66', 'track'])
      expect(HTTParty).to have_received(:get).with(
        'https://api.mapbox.com/v4/testuser.morning_run_4e481c66.json',
        query: { access_token: 'sk.test-token' },
        timeout: 30
      )
    end

    it 'returns nil when the tileset does not exist (non-2xx)' do
      allow(HTTParty).to receive(:get).and_return(response_double(body: '{"message":"Not Found"}', success: false))
      expect(uploader.find('missing_id')).to be_nil
    end

    it 'returns nil when the tileset has no vector layers (not renderable)' do
      allow(HTTParty).to receive(:get).and_return(response_double(body: '{"vector_layers":[]}', success: true))
      expect(uploader.find('empty_id')).to be_nil
    end

    it 'returns nil when the response body is not JSON' do
      allow(HTTParty).to receive(:get).and_return(response_double(body: 'not json', success: true))
      expect(uploader.find('weird_id')).to be_nil
    end
  end
end
