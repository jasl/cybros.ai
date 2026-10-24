namespace :model_catalog do
  desc "Retain configured provider models while following the current deployment catalog"
  task retain: :environment do
    # Installation work is finite, with one short transaction per configured lane.
    ModelProviderConfig.find_each do |policy|
      result = ModelProviders::RetainCatalog.call(account: policy.account, provider_id: policy.provider_id,
        expected_lock_version: policy.lock_version)
      abort "Catalog retention refused for #{policy.provider_id}: #{result.outcome}" unless result.done?
    end
  end
end

# The ordinary installation/upgrade path refreshes saved facts after schema and
# seeds. Initializers and runtime discovery deliberately perform no database writes.
Rake::Task["db:prepare"].enhance do
  Rake::Task["model_catalog:retain"].invoke
end
