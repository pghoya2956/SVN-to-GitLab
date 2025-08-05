class AddProgressFieldsToJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :jobs, :current_revision, :integer unless column_exists?(:jobs, :current_revision)
    add_column :jobs, :total_revisions, :integer unless column_exists?(:jobs, :total_revisions)
    add_column :jobs, :processing_speed, :float unless column_exists?(:jobs, :processing_speed)
    add_column :jobs, :eta_seconds, :integer unless column_exists?(:jobs, :eta_seconds)
  end
end
