class AddEstimatedCompletionAtToJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :jobs, :estimated_completion_at, :datetime
  end
end
