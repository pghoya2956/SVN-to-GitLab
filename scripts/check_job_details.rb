job = Job.find(14)
repo = job.repository

puts "=== Job #14 상세 정보 ==="
puts "Repository 정보:"
puts "  이름: #{repo.name}"
puts "  GitLab 프로젝트 ID: #{repo.gitlab_project_id}"
puts "  마이그레이션 방식: #{repo.migration_method}"
puts "  로컬 경로: #{repo.local_git_path}"

puts "\nJob 상태:"
puts "  상태: #{job.status}"
puts "  진행률: #{job.progress}% (calculate_progress: #{job.calculate_progress}%)"
puts "  현재/전체 리비전: #{job.current_revision}/#{job.total_revisions}"

if repo.local_git_path && Dir.exist?(repo.local_git_path)
  puts "\nGit 저장소 정보:"
  Dir.chdir(repo.local_git_path) do
    branch = `git branch --show-current 2>/dev/null`.strip
    count = `git rev-list --all --count 2>/dev/null`.strip
    latest = `git log -1 --oneline 2>/dev/null`.strip
    size = `du -sh . 2>/dev/null`.strip
    
    puts "  브랜치: #{branch}"
    puts "  커밋 수: #{count}"
    puts "  최신 커밋: #{latest}"
    puts "  저장소 크기: #{size}"
  end
else
  puts "\nGit 저장소가 아직 없거나 접근할 수 없습니다."
end

puts "\n최근 로그 (마지막 10줄):"
puts job.output_log&.lines&.last(10)&.join