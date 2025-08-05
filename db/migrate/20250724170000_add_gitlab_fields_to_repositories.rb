class AddGitlabFieldsToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :gitlab_project_id, :integer
    add_column :repositories, :gitlab_project_path, :string
    add_column :repositories, :gitlab_project_url, :string
    
    add_index :repositories, :gitlab_project_id
  end
end