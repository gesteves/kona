namespace :embeddings do
  desc "Enqueues an embedding job for every published, non-Short article (run once to seed the " \
       "related-articles vectors; rerun to recover dropped webhooks). Requires a running Sidekiq " \
       "worker to drain the queue."
  task backfill: :environment do
    ids = Articles.new.list
      .reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
      .filter_map { |a| a.sys&.id }

    ids.each { |id| ArticleEmbeddingJob.perform_async("embed", id) }
    puts "embeddings backfill enqueued for #{ids.size} articles (jobs drain on the Sidekiq worker)."
  end
end
