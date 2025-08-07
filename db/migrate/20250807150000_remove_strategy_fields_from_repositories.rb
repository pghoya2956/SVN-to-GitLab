class RemoveStrategyFieldsFromRepositories < ActiveRecord::Migration[7.1]
  def change
    remove_column :repositories, :tag_strategy, :string
    remove_column :repositories, :branch_strategy, :string
  end
end