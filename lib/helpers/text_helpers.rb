module TextHelpers
  def remove_widows(text)
    return if text.blank?
    words = text.split(/\s+/)
    return text if words.size == 1
    last_words = words.pop(2).join('&nbsp;')
    words.append(last_words).join(' ')
  end

  def comma_join_with_and(items)
    items.size <= 2 ? items.join(' and ') : [items[0..-2].join(', '), items[-1]].join(' and ')
  end
end
