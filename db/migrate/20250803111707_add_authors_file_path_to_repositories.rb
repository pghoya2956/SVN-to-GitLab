class AddAuthorsFilePathToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :authors_file_path, :string
  end
end
