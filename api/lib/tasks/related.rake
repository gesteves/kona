# The inspection tools for the "You May Also Like" ranking.
#
# ⚠️ These exist because no A/B test can operate at the traffic of this site. Thus a person reads
# these two reports to know if a change to the ranking helped.
namespace :related do
  desc "Prints the ranking of one article: the raw and the centered similarity, the taxonomy " \
       "overlap, the final score, the floor, and the MMR selection. Give the slug."
  task :inspect, [ :slug ] => :environment do |_task, args|
    slug = args[:slug].to_s
    abort("Give a slug: rake related:inspect[my-article]") if slug.blank?

    report = RelatedInspector.new.inspect_article(slug)
    abort(report[:error]) if report[:error].present?

    puts "#{report[:title]}  (#{report[:path]})"
    puts "floor #{format('%.4f', report[:floor])}   candidates #{report[:total]}   past the floor #{report[:above_floor]}"
    puts
    puts format("%-4s %-8s %-8s %-8s %-8s %-5s %-5s %s", "#", "raw", "centered", "overlap", "score", "keep", "MMR", "title")

    report[:rows].each_with_index do |row, index|
      puts format(
        "%-4d %-8.4f %-8.4f %-8.4f %-8.4f %-5s %-5s %s",
        index + 1, row[:raw], row[:centered], row[:overlap], row[:score],
        row[:above_floor] ? "yes" : "no", row[:selected] ? "yes" : "no", row[:title]
      )
    end
  end

  desc "Prints the health of the corpus: the spread of the similarity before and after the mean " \
       "subtraction, the coverage of the embeddings, and the vectors that are out of date."
  task audit: :environment do
    report = RelatedInspector.new.audit

    puts "articles      #{report[:total]}"
    puts "with a vector #{report[:with_vector]}  (#{report[:coverage]}%)"
    puts "out of date   #{report[:stale]}"
    puts
    puts "the similarity of each pair:"
    puts format("  raw       mean %+.4f   sd %.4f", report[:raw][:mean], report[:raw][:sd])
    puts format("  centered  mean %+.4f   sd %.4f", report[:centered][:mean], report[:centered][:sd])
    puts
    puts report[:verdict]

    next if report[:stale_ids].blank?

    puts
    puts "The embedding of each id below is older than the entry. Contentful never sends a webhook"
    puts "again, thus `rake embeddings:backfill` is the only correction."
    report[:stale_ids].each { |id| puts "  #{id}" }
  end
end
