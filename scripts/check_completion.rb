jobs = Job.where(id: [13, 14])
jobs.each do |job|
  puts "Job ##{job.id}:"
  puts "  상태: #{job.status}"
  puts "  진행률: #{job.progress}%"
  puts "  현재/전체 리비전: #{job.current_revision}/#{job.total_revisions}"
  
  # git svn이 끝났는지 확인
  if job.running? && job.repository.local_git_path
    git_svn_pid = `pgrep -f 'git.*svn.*#{job.id}' 2>/dev/null`.strip
    puts "  git-svn 프로세스: #{git_svn_pid.empty? ? '없음' : git_svn_pid}"
    
    if git_svn_pid.empty? && job.progress >= 90
      puts "  => git svn clone이 완료된 것으로 보임"
      
      # 마지막 로그 확인
      last_log = job.output_log&.lines&.last(5)&.join
      puts "  마지막 로그:"
      puts last_log
    end
  end
  puts
end