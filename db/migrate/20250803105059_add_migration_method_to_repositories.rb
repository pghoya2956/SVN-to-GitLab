class AddMigrationMethodToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :migration_method, :integer, default: 0, null: false
    add_column :repositories, :svn_structure, :jsonb
    
    # authors_mapping already exists as text, convert to jsonb
    change_column :repositories, :authors_mapping, :jsonb, using: 'authors_mapping::jsonb'
    
    add_index :repositories, :migration_method
  end
end
