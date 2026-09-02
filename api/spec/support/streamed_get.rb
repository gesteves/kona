# Stubs `HTTParty.get` for the code that reads a body through `ApplicationService#download`.
#
# ⚠️ That method reads with `stream_body: true` and a block, thus a plain `and_return` gives it no
# body at all. This helper gives the body to the block in fragments, as Net::HTTP does.
module StreamedGet
  # @param url [String, Object] The URL to match, or an RSpec matcher such as `anything`.
  # @param body [String] The body of the response.
  # @param code [Integer] The HTTP status.
  # @param headers [Hash] The response headers, with lowercase names.
  # @param fragments [Integer] The number of pieces to give the body in.
  # @return [void]
  def stub_streamed_get(url = anything, body:, code: 200, headers: {}, fragments: 1)
    http_response = instance_double(Net::HTTPResponse, code: code.to_s)
    allow(http_response).to receive(:[]) { |name| headers[name.to_s.downcase] }
    response = instance_double(HTTParty::Response, success?: (200..299).cover?(code), code: code,
                                                   body: body, headers: headers)

    allow(HTTParty).to receive(:get).with(url, anything) do |_url, _options, &block|
      if block
        split_body(body, fragments).each do |piece|
          block.call(HTTParty::ResponseFragment.new(piece, http_response, nil))
        end
      end
      response
    end
  end

  private

  # @return [Array<String>] The body in `count` pieces of nearly the same size.
  def split_body(body, count)
    return [ body ] if count <= 1 || body.empty?

    size = (body.bytesize / count.to_f).ceil
    (0...body.bytesize).step(size).map { |offset| body.byteslice(offset, size) }
  end
end

RSpec.configure do |config|
  config.include StreamedGet

  # The `.test` hosts of the specs resolve to nothing. This gives each name a public address, thus
  # PublicAddress accepts it. An example about the check itself stubs this again.
  config.before do
    allow(PublicAddress).to receive(:addresses).and_wrap_original do |original, name|
      name.match?(/\A[0-9a-f.:]+\z/i) ? original.call(name) : [ IPAddr.new("203.0.113.1") ]
    end
  end
end
