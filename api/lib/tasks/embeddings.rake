namespace :embeddings do
  desc "Enqueues an embedding job for every published entry, Articles AND Shorts (run once to seed " \
       "the related-articles vectors; rerun to recover dropped webhooks). Shorts are embedded too so " \
       "a Short page's related widget has the Short's own query vector — they're just excluded from " \
       "the results (full articles only). Requires a running Sidekiq worker to drain the queue."
  task backfill: :environment do
    ids = Articles.new.list
      .reject { |a| a.draft || a.path.blank? }
      .filter_map { |a| a.sys&.id }

    ids.each { |id| ArticleEmbeddingJob.perform_async("embed", id) }
    puts "embeddings backfill enqueued for #{ids.size} entries (jobs drain on the Sidekiq worker)."
  end
end
