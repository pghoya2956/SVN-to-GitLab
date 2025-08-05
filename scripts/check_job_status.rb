puts '=== 현재 작업 상황 ==='
puts Time.current.strftime('%Y-%m-%d %H:%M:%S')
puts

jobs = Job.where(id: [13, 14]).order(:id)
jobs.each do |job|
  puts "Job ##{job.id} - #{job.repository.name}"
  puts "  상태: #{job.status}"
  puts "  진행률: #{job.progress}%"
  puts "  리비전: #{job.current_revision}/#{job.total_revisions}"
  puts "  시작: #{job.started_at}"
  puts "  완료: #{job.completed_at}" if job.completed_at
  puts "  경과 시간: #{((Time.current - job.started_at) / 60).round(1)}분" if job.started_at
  puts "  GitLab 프로젝트 ID: #{job.repository.gitlab_project_id}"
  puts "  로컬 Git 경로: #{job.repository.local_git_path}"
  
  if job.completed? && job.repository.local_git_path && Dir.exist?(job.repository.local_git_path)
    size = `du -sh #{job.repository.local_git_path} 2>/dev/null`.strip
    puts "  Git 저장소 크기: #{size}"
  end
  
  if job.failed?
    puts "  에러: #{job.error_log&.lines&.last(2)&.join&.strip}"
  end
  
  puts
end

# 전체 작업 통계
puts "=== 전체 작업 통계 ==="
puts "실행 중: #{Job.where(status: 'running').count}"
puts "완료: #{Job.where(status: 'completed').count}"
puts "실패: #{Job.where(status: 'failed').count}"
puts "대기: #{Job.where(status: 'pending').count}"