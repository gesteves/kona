require 'spec_helper'

RSpec.describe ContextHelpers do
  def with_context(value)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CONTEXT').and_return(value)
  end

  it 'is not on Netlify without a CONTEXT' do
    with_context(nil)
    expect(netlify?).to be false
    expect(production?).to be false
    expect(dev?).to be false
  end

  it 'is on Netlify in production' do
    with_context('production')
    expect(netlify?).to be true
    expect(production?).to be true
    expect(dev?).to be false
  end

  it 'is on Netlify (but not production) for previews' do
    with_context('deploy-preview')
    expect(netlify?).to be true
    expect(production?).to be false
  end

  it 'detects netlify dev' do
    with_context('dev')
    expect(netlify?).to be true
    expect(dev?).to be true
    expect(production?).to be false
  end
end
