#!/usr/bin/env ruby

# Example script for starting a migration
# Usage: GITLAB_TOKEN=your-token-here rails runner scripts/start_migration_example.rb

# GitLab 토큰 테스트
require 'gitlab'

gitlab_token = ENV['GITLAB_TOKEN'] || raise("GITLAB_TOKEN environment variable is required")
puts "Testing GitLab token: #{gitlab_token[0..20]}..."

begin
  client = Gitlab.client(
    endpoint: 'https://gitlab.com/api/v4',
    private_token: gitlab_token
  )
  
  user = client.user
  puts "✓ Token valid! User: #{user.username}"
  puts "  Email: #{user.email}"
rescue => e
  puts "✗ Token invalid: #{e.message}"
  exit 1
end

# 기존 실행 중인 Job 취소
running_jobs = Job.where(status: 'running')
if running_jobs.any?
  running_jobs.update_all(status: 'cancelled', completed_at: Time.current)
  puts "\nCancelled #{running_jobs.count} running job(s)"
end

# 기존 디렉토리 정리
git_dir = '/app/git_repos/repository_1'
if File.directory?(git_dir)
  FileUtils.rm_rf(git_dir)
  puts "Cleaned up existing directory"
end

# 새 Job 생성
repo = Repository.find(1)
job = repo.jobs.create!(
  job_type: 'migration',
  status: 'pending',
  phase: 'pending'
)

puts "\nCreated new Job ID: #{job.id}"
puts "Starting migration..."
puts "- Batch size: #{ENV.fetch('SVN_BATCH_SIZE', 100)}"
puts "- Repository: #{repo.svn_url}"

# Sidekiq로 실행
MigrationJob.perform_async(job.id, gitlab_token)
puts "\nJob enqueued to Sidekiq!"
puts "Check progress at: http://localhost:3000/jobs/#{job.id}"

# 초기 상태 확인 (5초 대기)
sleep 5
job.reload
puts "\nInitial status after 5 seconds:"
puts "- Status: #{job.status}"
puts "- Phase: #{job.phase}"
puts "- Progress: #{job.progress}%"

if job.error_log.present?
  puts "\nError occurred:"
  puts job.error_log.lines.last(3).join
end