# The inspection tools for the "You May Also Like" ranking.
#
# ⚠️ These exist because no A/B test can operate at the traffic of this site. Thus a person reads
# these reports to know if a change to the ranking helped.
namespace :related do
  desc "Prints the ranking of one article: the BM25 similarity, the taxonomy overlap, the link, " \
       "the prior, the final score, the MMR selection, and the shared terms. Give the slug."
  task :inspect, [ :slug ] => :environment do |_task, args|
    slug = args[:slug].to_s
    abort("Give a slug: rake related:inspect[my-article]") if slug.blank?

    report = RelatedInspector.new.inspect_article(slug)
    abort(report[:error]) if report[:error].present?

    puts "#{report[:title]}  (#{report[:path]})"
    puts "candidates #{report[:total]}"
    puts
    puts format("%-4s %-8s %-8s %-5s %-8s %-8s %-5s %-30s %s",
                "#", "lexical", "overlap", "link", "prior", "score", "MMR", "shared terms", "title")

    report[:rows].each_with_index do |row, index|
      puts format(
        "%-4d %-8.4f %-8.4f %-5s %-8.4f %-8.4f %-5s %-30.30s %s",
        index + 1, row[:lexical], row[:overlap], row[:link] ? "yes" : "no", row[:prior], row[:score],
        row[:selected] ? "yes" : "no", Array(row[:terms]).join(", "), row[:title]
      )
    end
  end

  desc "Prints the health of the corpus: how much of it the index holds, how many entries get a " \
       "full section, and the spread of the similarity of each pair."
  task audit: :environment do
    report = RelatedInspector.new.audit

    puts "published entries  #{report[:total]}"
    puts "in the index       #{report[:indexed]}  (#{report[:coverage]}%)"
    puts "with a list        #{report[:keyed]}"
    puts "with a short list  #{report[:short]}"
    puts
    puts "the similarity of each pair:"
    puts format("  mean %+.4f   sd %.4f", report[:spread][:mean], report[:spread][:sd])
  end

  desc "Prints the recall of the section against the real navigation of the readers, from " \
       "Plausible. The lists of 2026-09-05 gave 0.389 before the links and the prior."
  task evaluate: :environment do
    report = RelatedInspector.new.evaluate

    if report[:recall].nil?
      abort("No transitions. Plausible is not configured, or it is not available.")
    end

    puts "pages     #{report[:pages]}"
    puts "recall@#{RelatedInspector::SECTION_COUNT}  #{report[:hits]}/#{report[:total]} = #{report[:recall]}"
  end
end
