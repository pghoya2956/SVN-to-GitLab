class AddSyncDetailsToJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :jobs, :start_revision, :integer
    add_column :jobs, :end_revision, :integer
    add_column :jobs, :parent_job_id, :integer
    add_index :jobs, :parent_job_id
  end
end
