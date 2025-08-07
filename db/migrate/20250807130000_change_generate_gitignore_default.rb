class ChangeGenerateGitignoreDefault < ActiveRecord::Migration[7.1]
  def change
    change_column_default :repositories, :generate_gitignore, from: true, to: false
  end
end