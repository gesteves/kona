require "rails_helper"

RSpec.describe ArticleLinks do
  let(:paths) { { "a" => "/2024/05/01/a/", "b" => "/2024/04/01/b/", "c" => "/2024/03/01/c/" } }

  def links(corpus, site_url: "https://www.example.com")
    described_class.new(corpus, paths, site_url: site_url)
  end

  def body(text)
    { "a" => { intro: nil, body: text } }
  end

  it "finds a root-relative link" do
    expect(links(body("Read [the report](/2024/04/01/b/).")).links_of("a")).to eq(%w[b])
  end

  it "finds a link with the host of the site" do
    expect(links(body("https://www.example.com/2024/04/01/b/")).links_of("a")).to eq(%w[b])
  end

  # The two forms of one site are equal, and the slash at the end is optional.
  it "reads a host with no www and a path with no slash at the end" do
    expect(links(body("[b](https://example.com/2024/04/01/b)")).links_of("a")).to eq(%w[b])
  end

  it "finds a link in an href and ignores a fragment" do
    expect(links(body('<a href="/2024/04/01/b/#swim">the swim</a>')).links_of("a")).to eq(%w[b])
  end

  it "ignores a link to another site" do
    expect(links(body("https://other.com/2024/04/01/b/")).links_of("a")).to eq([])
  end

  # ⚠️ Never write the host name in the code. With no SITE_URL, an absolute link is not a link.
  it "ignores an absolute link when SITE_URL has no value" do
    corpus = body("https://www.example.com/2024/04/01/b/ and [c](/2024/03/01/c/)")

    expect(links(corpus, site_url: nil).links_of("a")).to eq(%w[c])
  end

  it "ignores a link to a path that no entry has" do
    expect(links(body("[gone](/2024/04/01/gone/)")).links_of("a")).to eq([])
  end

  it "ignores a link to the entry itself" do
    expect(links(body("[me](/2024/05/01/a/)")).links_of("a")).to eq([])
  end

  it "reads the intro and the body, and names each target one time" do
    corpus = { "a" => { intro: "[b](/2024/04/01/b/)", body: "[b again](/2024/04/01/b/) [c](/2024/03/01/c/)" } }

    expect(links(corpus).links_of("a")).to contain_exactly("b", "c")
  end

  it "is true in either direction" do
    subject = links(body("[b](/2024/04/01/b/)"))

    expect(subject.linked?("a", "b")).to be(true)
    expect(subject.linked?("b", "a")).to be(true)
    expect(subject.linked?("a", "c")).to be(false)
  end

  it "does not raise for an entry with no text" do
    expect(links({ "a" => nil }).links_of("a")).to eq([])
  end
end
