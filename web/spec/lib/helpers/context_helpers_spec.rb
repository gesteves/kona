require 'spec_helper'

RSpec.describe ContextHelpers do
  def with_env(deploy_context: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('DEPLOY_CONTEXT').and_return(deploy_context)
  end

  it 'is not production without any context' do
    with_env
    expect(production?).to be false
    expect(deploy_context).to be_nil
  end

  it 'is production when DEPLOY_CONTEXT says so' do
    with_env(deploy_context: 'production')
    expect(production?).to be true
    expect(deploy_context).to eq('production')
  end

  it 'is not production for any other context' do
    with_env(deploy_context: 'branch-preview')
    expect(production?).to be false
  end
end
