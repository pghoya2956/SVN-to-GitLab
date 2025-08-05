class AddIncrementalSyncFieldsToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :local_git_path, :string
    add_column :repositories, :last_synced_at, :datetime
    add_column :repositories, :last_synced_revision, :integer
    add_column :repositories, :enable_incremental_sync, :boolean, default: false
    
    add_index :repositories, :enable_incremental_sync
    add_index :repositories, :last_synced_at
  end
end
