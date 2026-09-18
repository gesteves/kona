require 'spec_helper'

RSpec.describe MemoizationHelpers do
  before { MemoizationHelpers.collection_store.clear }

  describe '#memoize_by_collection' do
    it 'computes once per collection identity' do
      collection = [ 1, 2, 3 ]
      calls = 0

      2.times { memoize_by_collection(:test_value, collection) { calls += 1; collection.sum } }

      expect(calls).to eq(1)
      expect(memoize_by_collection(:test_value, collection) { raise 'should not recompute' }).to eq(6)
    end

    it 'recomputes when the collection is a different object (a data reload)' do
      first = memoize_by_collection(:test_value, [ 1 ]) { 'first' }
      second = memoize_by_collection(:test_value, [ 1 ]) { 'second' }

      expect(first).to eq('first')
      expect(second).to eq('second') # equal contents, different identity
    end

    it 'recomputes when any one of several collections is a different object' do
      articles = [ 1 ]
      pages = [ 2 ]
      calls = 0

      2.times { memoize_by_collection(:pair, articles, pages) { calls += 1 } }
      memoize_by_collection(:pair, articles, [ 2 ]) { calls += 1 }

      expect(calls).to eq(2)
    end

    it 'keys memos independently by name' do
      collection = [ 1 ]
      expect(memoize_by_collection(:a, collection) { 'a' }).to eq('a')
      expect(memoize_by_collection(:b, collection) { 'b' }).to eq('b')
    end
  end

  describe '#memoize_entry' do
    let(:collection) { [ 1 ] }

    it 'computes once per key, including false values' do
      calls = 0

      2.times { memoize_entry(:test_memo, 'id-1', collection) { calls += 1; false } }

      expect(calls).to eq(1)
      expect(memoize_entry(:test_memo, 'id-1', collection) { raise 'should not recompute' }).to be(false)
    end

    it 'caches different keys separately' do
      expect(memoize_entry(:test_memo, 'id-1', collection) { 1 }).to eq(1)
      expect(memoize_entry(:test_memo, 'id-2', collection) { 2 }).to eq(2)
    end

    it 'starts a new store when the collection is a different object' do
      expect(memoize_entry(:test_memo, 'id-1', [ 1 ]) { 'first' }).to eq('first')
      expect(memoize_entry(:test_memo, 'id-1', [ 1 ]) { 'second' }).to eq('second')
    end

    it 'computes fresh (uncached) when the key is blank' do
      calls = 0

      2.times { memoize_entry(:test_memo, nil, collection) { calls += 1 } }

      expect(calls).to eq(2)
    end
  end

  # ⚠️ A nil collection is a helper with no data, for example in a spec. The first call must still
  # yield: `nil.equal?(nil)` is true, and a store with no entry gave nil back with no call.
  it 'yields on the first call for a nil collection, then keeps the value' do
    calls = 0
    first = memoize_by_collection(:nil_collection, nil) { calls += 1; { a: 1 } }
    second = memoize_by_collection(:nil_collection, nil) { calls += 1; { a: 2 } }

    expect(first).to eq(a: 1)
    expect(second).to equal(first)
    expect(calls).to eq(1)
  end
end
