require "ostruct"

# Puts parsed JSON, that is, a Hash or an Array, into an OpenStruct at each level. Thus the code can
# read it with dot notation, as it read the `data.*` objects of Middleman. That is why the weather
# helpers needed almost no change. A key that is absent gives nil, as in OpenStruct and in
# Middleman.
module DeepOstruct
  module_function

  def wrap(obj)
    case obj
    when Hash
      OpenStruct.new(obj.transform_values { |v| wrap(v) })
    when Array
      obj.map { |v| wrap(v) }
    else
      obj
    end
  end
end
