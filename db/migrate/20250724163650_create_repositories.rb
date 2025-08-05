class CreateRepositories < ActiveRecord::Migration[7.1]
  def change
    create_table :repositories do |t|
      t.string :name
      t.string :svn_url
      t.string :auth_type
      t.string :username
      t.string :encrypted_password
      t.text :ssh_key
      t.string :branch_option
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end
  end
end
