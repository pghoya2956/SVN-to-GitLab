class AddRevisionTrackingToJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :jobs, :current_revision, :integer
    add_column :jobs, :total_revisions, :integer
  end
end
