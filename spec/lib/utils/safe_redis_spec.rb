require 'spec_helper'
require_relative '../../../lib/utils/safe_redis'

RSpec.describe SafeRedis do
  let(:underlying) { instance_double(Redis) }
  let(:safe) do
    allow(Redis).to receive(:new).and_return(underlying)
    SafeRedis.new
  end

  context 'when Redis is reachable' do
    it 'forwards reads to the underlying client' do
      expect(underlying).to receive(:get).with('foo').and_return('bar')
      expect(safe.get('foo')).to eq('bar')
      expect(safe.available?).to be true
    end

    it 'forwards mget to the underlying client' do
      expect(underlying).to receive(:mget).with('a', 'b').and_return(['1', nil])
      expect(safe.mget('a', 'b')).to eq(['1', nil])
    end

    it 'forwards writes to the underlying client' do
      expect(underlying).to receive(:setex).with('k', 60, 'v').and_return('OK')
      expect(safe.setex('k', 60, 'v')).to eq('OK')
    end
  end

  context 'when the connection fails' do
    before do
      allow(underlying).to receive(:get).and_raise(Redis::CannotConnectError, 'boom')
      allow(underlying).to receive(:set).and_raise(Redis::CannotConnectError, 'boom')
      allow(underlying).to receive(:mget).and_raise(Redis::TimeoutError, 'slow')
    end

    it 'returns nil from get and marks itself unavailable' do
      expect { expect(safe.get('foo')).to be_nil }.to output(/Redis unavailable/).to_stderr
      expect(safe.available?).to be false
    end

    it 'returns nil from writes' do
      expect { safe.set('k', 'v') }.to output(/Redis unavailable/).to_stderr
      expect(safe.set('k', 'v')).to be_nil
    end

    it 'returns an array of nils from mget matching the key count' do
      expect { expect(safe.mget('a', 'b', 'c')).to eq([nil, nil, nil]) }.to output(/Redis unavailable/).to_stderr
    end

    it 'short-circuits subsequent calls without retrying the underlying client' do
      expect { safe.get('first') }.to output(/Redis unavailable/).to_stderr
      expect(underlying).not_to receive(:get)
      expect(safe.get('second')).to be_nil
    end
  end

  it 'lets non-connection errors propagate' do
    allow(underlying).to receive(:get).and_raise(ArgumentError, 'bad')
    expect { safe.get('foo') }.to raise_error(ArgumentError, 'bad')
  end
end
