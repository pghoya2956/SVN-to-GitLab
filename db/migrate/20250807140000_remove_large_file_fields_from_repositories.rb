class RemoveLargeFileFieldsFromRepositories < ActiveRecord::Migration[7.1]
  def change
    remove_column :repositories, :large_file_handling, :string
    remove_column :repositories, :max_file_size_mb, :integer
  end
end