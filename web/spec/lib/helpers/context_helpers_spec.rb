require 'spec_helper'

RSpec.describe ContextHelpers do
  def with_env(context: nil, deploy_context: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CONTEXT').and_return(context)
    allow(ENV).to receive(:[]).with('DEPLOY_CONTEXT').and_return(deploy_context)
  end

  it 'is not on Netlify and not production without any context' do
    with_env
    expect(netlify?).to be false
    expect(production?).to be false
    expect(deploy_context).to be_nil
  end

  it 'is on Netlify in production via CONTEXT' do
    with_env(context: 'production')
    expect(netlify?).to be true
    expect(production?).to be true
  end

  it 'is on Netlify (but not production) for previews' do
    with_env(context: 'deploy-preview')
    expect(netlify?).to be true
    expect(production?).to be false
  end

  it 'is production via the platform-neutral DEPLOY_CONTEXT, without being on Netlify' do
    with_env(deploy_context: 'production')
    expect(netlify?).to be false
    expect(production?).to be true
  end

  it 'prefers DEPLOY_CONTEXT over CONTEXT when both are set' do
    with_env(context: 'production', deploy_context: 'branch-preview')
    expect(production?).to be false
  end
end
