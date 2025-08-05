class CreateGitlabTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :gitlab_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :endpoint
      t.string :encrypted_token

      t.timestamps
    end
  end
end
