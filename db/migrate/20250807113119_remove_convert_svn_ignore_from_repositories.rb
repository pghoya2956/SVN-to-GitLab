class RemoveConvertSvnIgnoreFromRepositories < ActiveRecord::Migration[7.1]
  def change
    remove_column :repositories, :convert_svn_ignore, :boolean
  end
end
