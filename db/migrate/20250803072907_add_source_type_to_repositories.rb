class AddSourceTypeToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :source_type, :integer, default: 0, null: false
    add_index :repositories, :source_type
  end
end
