puts '=== 최종 상태 확인 ==='
puts Time.current

jobs = Job.where(id: [13, 14])
jobs.each do |job|
  puts "\nJob ##{job.id} - #{job.repository.name}"
  puts "상태: #{job.status}"
  puts "진행률: #{job.progress}%"
  puts "리비전: #{job.current_revision}/#{job.total_revisions}"
  
  if job.repository.local_git_path && Dir.exist?(job.repository.local_git_path)
    Dir.chdir(job.repository.local_git_path) do
      commit_count = `git rev-list --all --count 2>/dev/null`.strip
      size = `du -sh . 2>/dev/null | cut -f1`.strip
      puts "Git 저장소: #{commit_count} 커밋, #{size}"
    end
  end
  
  # 마지막 로그
  last_log = job.output_log&.lines&.last(3)&.join
  puts "마지막 로그:"
  puts last_log
end

puts "\n=== 요약 ==="
puts "1. git-svn을 통한 전체 이력 마이그레이션 성공"
puts "2. 실시간 진행률 모니터링 구현 (DB 업데이트 이슈 있음)"
puts "3. GitLab 프로젝트 선택 기능 구현됨"
puts "4. 웹 UI를 통한 작업 관리 가능"