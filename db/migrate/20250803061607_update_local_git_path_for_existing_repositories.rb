class UpdateLocalGitPathForExistingRepositories < ActiveRecord::Migration[7.1]
  def up
    # Skip if Repository model is not ready or has no records
    return unless table_exists?(:repositories) && table_exists?(:jobs)
    
    # Use raw SQL to avoid model dependencies
    execute <<-SQL
      UPDATE repositories 
      SET local_git_path = CONCAT('#{Rails.root}/tmp/migrations/', 
        (SELECT id FROM jobs WHERE repository_id = repositories.id AND job_type = 'migration' ORDER BY id DESC LIMIT 1), 
        '/git_repo')
      WHERE EXISTS (
        SELECT 1 FROM jobs 
        WHERE repository_id = repositories.id 
        AND job_type = 'migration'
      )
    SQL
  end
  
  def down
    # This migration is not reversible as it updates existing data
  end
end
