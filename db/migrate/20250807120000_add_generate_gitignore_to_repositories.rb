class AddGenerateGitignoreToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :generate_gitignore, :boolean, default: true
    remove_column :repositories, :lfs_file_patterns, :text
  end
end