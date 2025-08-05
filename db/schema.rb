# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2025_08_05_100644) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "gitlab_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "endpoint"
    t.string "encrypted_token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_gitlab_tokens_on_user_id"
  end

  create_table "jobs", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "repository_id", null: false
    t.string "status", default: "pending"
    t.string "job_type"
    t.text "parameters"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "progress", default: 0
    t.text "output_log"
    t.text "error_log"
    t.string "result_url"
    t.integer "total_commits"
    t.integer "processed_commits", default: 0
    t.integer "total_files"
    t.integer "processed_files", default: 0
    t.string "sidekiq_job_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.integer "start_revision"
    t.integer "end_revision"
    t.integer "parent_job_id"
    t.integer "current_revision"
    t.integer "total_revisions"
    t.float "processing_speed"
    t.integer "eta_seconds"
    t.string "phase", default: "pending"
    t.jsonb "phase_details", default: {}
    t.boolean "resumable", default: false
    t.jsonb "checkpoint_data", default: {}
    t.integer "retry_count", default: 0
    t.index ["job_type"], name: "index_jobs_on_job_type"
    t.index ["parent_job_id"], name: "index_jobs_on_parent_job_id"
    t.index ["phase"], name: "index_jobs_on_phase"
    t.index ["repository_id"], name: "index_jobs_on_repository_id"
    t.index ["resumable"], name: "index_jobs_on_resumable"
    t.index ["sidekiq_job_id"], name: "index_jobs_on_sidekiq_job_id"
    t.index ["status"], name: "index_jobs_on_status"
    t.index ["user_id"], name: "index_jobs_on_user_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.string "name"
    t.string "svn_url"
    t.string "auth_type"
    t.string "username"
    t.string "encrypted_password"
    t.text "ssh_key"
    t.string "branch_option"
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "gitlab_project_id"
    t.string "gitlab_project_path"
    t.string "gitlab_project_url"
    t.string "migration_type", default: "standard"
    t.boolean "preserve_history", default: true
    t.jsonb "authors_mapping"
    t.text "ignore_patterns"
    t.string "tag_strategy", default: "all"
    t.string "branch_strategy", default: "all"
    t.string "commit_message_prefix"
    t.string "large_file_handling", default: "git-lfs"
    t.integer "max_file_size_mb", default: 100
    t.string "local_git_path"
    t.datetime "last_synced_at"
    t.integer "last_synced_revision"
    t.boolean "enable_incremental_sync", default: false
    t.integer "source_type", default: 0, null: false
    t.integer "migration_method", default: 0, null: false
    t.jsonb "svn_structure"
    t.string "authors_file_path"
    t.index ["enable_incremental_sync"], name: "index_repositories_on_enable_incremental_sync"
    t.index ["gitlab_project_id"], name: "index_repositories_on_gitlab_project_id"
    t.index ["last_synced_at"], name: "index_repositories_on_last_synced_at"
    t.index ["migration_method"], name: "index_repositories_on_migration_method"
    t.index ["migration_type"], name: "index_repositories_on_migration_type"
    t.index ["source_type"], name: "index_repositories_on_source_type"
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "gitlab_tokens", "users"
  add_foreign_key "jobs", "repositories"
  add_foreign_key "jobs", "users"
  add_foreign_key "repositories", "users"
end
