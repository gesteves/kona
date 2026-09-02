require "ostruct"

# Puts parsed JSON, that is, a Hash or an Array, into an OpenStruct at each level. Thus the code can
# read it with dot notation, as it read the `data.*` objects of Middleman. That is why the weather
# helpers needed almost no change. A key that is absent gives nil, as in OpenStruct and in
# Middleman.
module DeepOstruct
  module_function

  # ⚠️ OpenStruct defines an accessor for each key, and one of these names would replace a method
  # that Rails calls on each object, with no message at the write and a strange error later.
  # No Contentful field has such a name today, and this stops the first one at the wrap.
  SHADOWED_KEYS = %w[class method send object_id instance_variable_get define_singleton_method].freeze

  def wrap(obj)
    case obj
    when Hash
      shadowed = obj.keys.map(&:to_s) & SHADOWED_KEYS
      raise ArgumentError, "DeepOstruct cannot wrap a key named #{shadowed.first.inspect}" if shadowed.any?

      OpenStruct.new(obj.transform_values { |v| wrap(v) })
    when Array
      obj.map { |v| wrap(v) }
    else
      obj
    end
  end
end
