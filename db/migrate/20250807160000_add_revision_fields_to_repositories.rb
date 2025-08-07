class AddRevisionFieldsToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :total_revisions, :integer
    add_column :repositories, :latest_revision, :integer
    
    add_index :repositories, :total_revisions
  end
end