class AddLastDetectedAtToRepositories < ActiveRecord::Migration[7.1]
  def change
    add_column :repositories, :last_detected_at, :datetime
  end
end
