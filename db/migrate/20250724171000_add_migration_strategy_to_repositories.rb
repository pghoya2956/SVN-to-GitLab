class AddMigrationStrategyToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :migration_type, :string, default: 'standard'
    add_column :repositories, :preserve_history, :boolean, default: true
    add_column :repositories, :authors_mapping, :text
    add_column :repositories, :ignore_patterns, :text
    add_column :repositories, :tag_strategy, :string, default: 'all'
    add_column :repositories, :branch_strategy, :string, default: 'all'
    add_column :repositories, :commit_message_prefix, :string
    add_column :repositories, :large_file_handling, :string, default: 'git-lfs'
    add_column :repositories, :max_file_size_mb, :integer, default: 100
    
    add_index :repositories, :migration_type
  end
end