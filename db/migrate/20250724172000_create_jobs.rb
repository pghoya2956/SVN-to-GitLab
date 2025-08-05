class CreateJobs < ActiveRecord::Migration[7.1]
  def change
    create_table :jobs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      t.string :status, default: 'pending'
      t.string :job_type
      t.text :parameters
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :progress, default: 0
      t.text :output_log
      t.text :error_log
      t.string :result_url
      t.integer :total_commits
      t.integer :processed_commits, default: 0
      t.integer :total_files
      t.integer :processed_files, default: 0
      t.string :sidekiq_job_id

      t.timestamps
    end
    
    add_index :jobs, :status
    add_index :jobs, :job_type
    add_index :jobs, :sidekiq_job_id
  end
end