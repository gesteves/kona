require "rails_helper"

RSpec.describe ContentfulConsumer do
  let(:host_class) do
    Class.new(ApplicationService) do
      include ContentfulConsumer
      public :find_cached_item

      def self.name = "SpecConsumer"
    end
  end
  let(:host) { host_class.new }
  let(:client) { instance_double(ContentfulClient) }
  let(:query) { "query($id: String!) { things(where: { sys: { id: $id } }) { items { sys { id } } } }" }

  before do
    allow(ContentfulClient).to receive(:new).with("SpecConsumer").and_return(client)
    keys = $redis.keys("spec:item:*")
    $redis.del(*keys) if keys.any?
  end

  after do
    keys = $redis.keys("spec:item:*")
    $redis.del(*keys) if keys.any?
  end

  def find(id) = host.find_cached_item(id, query: query, collection: :things, cache_key: "spec:item", context: "spec")

  it "gives the item with snake_case keys and dot access, and keeps it in the cache" do
    allow(client).to receive(:items).with(query, { id: "t1" }, collection: :things).and_return([ { firstName: "Ada", sys: { id: "t1" } } ])

    expect(find("t1").first_name).to eq("Ada")
    expect(find("t1").first_name).to eq("Ada")
    expect(client).to have_received(:items).once
  end

  it "gives nil for a blank id and asks Contentful nothing" do
    allow(client).to receive(:items)

    expect(find(nil)).to be_nil
    expect(find("")).to be_nil
    expect(client).not_to have_received(:items)
  end

  # ⚠️ A visitor can reach a widget path with an unknown id through the proxy of the site. The miss
  # stays in the cache, thus such an id does not cost one Contentful query for each request.
  it "keeps a miss in the cache for a short time" do
    allow(client).to receive(:items).and_return([])

    expect(find("nope")).to be_nil
    expect(find("nope")).to be_nil
    expect(client).to have_received(:items).once
    expect($redis.ttl("spec:item:nope")).to be_between(1, 60)
  end

  it "gives nil, and does not raise, when Contentful fails" do
    allow(client).to receive(:items).and_raise(ApplicationService::HttpError.new(500, "", "contentful"))

    expect(find("t1")).to be_nil
  end
end
