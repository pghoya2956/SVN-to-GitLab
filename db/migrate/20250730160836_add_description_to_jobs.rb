class AddDescriptionToJobs < ActiveRecord::Migration[7.1]
  def change
    add_column :jobs, :description, :text
  end
end
