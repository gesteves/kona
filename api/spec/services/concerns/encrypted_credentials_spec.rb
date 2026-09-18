require "rails_helper"

RSpec.describe EncryptedCredentials do
  let(:store) do
    Class.new do
      include EncryptedCredentials
    end.tap do |klass|
      klass.const_set(:REDIS_KEY, "spec:credentials")
      klass.const_set(:ENCRYPTION_SALT, "spec salt")
    end
  end

  after { $redis.del("spec:credentials") }

  it "encrypts a secret, thus Redis never holds it in the clear, and decrypts it again" do
    sealed = store.send(:encrypt, "an app password")

    expect(sealed).not_to include("an app password")
    expect(store.send(:decrypt, sealed)).to eq("an app password")
  end

  # ⚠️ A message from another key gives nil, and the page then says "not connected". It must not
  # raise on each page that shows the status.
  it "gives nil, and does not raise, for a message that it cannot read" do
    expect(store.send(:decrypt, "not-a-message")).to be_nil
    expect(store.send(:decrypt, nil)).to be_nil
    expect(store.send(:decrypt, "")).to be_nil
  end

  it "makes a different key for each salt" do
    other = Class.new { include EncryptedCredentials }
    other.const_set(:REDIS_KEY, "spec:other")
    other.const_set(:ENCRYPTION_SALT, "other salt")

    expect(other.send(:decrypt, store.send(:encrypt, "secret"))).to be_nil
  end

  it "removes the full store" do
    $redis.hset("spec:credentials", "field", "value")

    store.clear

    expect($redis.exists?("spec:credentials")).to be(false)
  end
end
