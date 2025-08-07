class AddGitignoreFieldsToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :convert_svn_ignore, :boolean, default: true
    add_column :repositories, :lfs_file_patterns, :text
  end
end
