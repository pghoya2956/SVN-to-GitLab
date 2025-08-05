class UpdateLocalGitPathForExistingRepositories < ActiveRecord::Migration[7.1]
  def up
    Repository.find_each do |repository|
      # Check for git repositories in tmp/migrations
      migration_path = Rails.root.join('tmp', 'migrations', repository.jobs.where(job_type: 'migration').last&.id.to_s, 'git_repo')
      
      if File.directory?(migration_path)
        repository.update!(local_git_path: migration_path.to_s)
        puts "Updated repository ##{repository.id} with git path: #{migration_path}"
      end
    end
  end
  
  def down
    # This migration is not reversible as it updates existing data
  end
end
