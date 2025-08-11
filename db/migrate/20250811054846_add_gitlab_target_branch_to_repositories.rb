class AddGitlabTargetBranchToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :gitlab_target_branch, :string, default: 'main'
  end
end
