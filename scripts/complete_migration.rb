# 실행 중인 작업들 완료 처리
jobs = Job.where(status: 'running')
puts "실행 중인 작업: #{jobs.count}개"

jobs.each do |job|
  puts "\nJob ##{job.id} 처리 중..."
  
  # git-svn 프로세스 확인
  git_svn_pid = `pgrep -f 'git.*svn.*#{job.id}' 2>/dev/null`.strip
  
  if git_svn_pid.empty?
    puts "  git-svn 프로세스 없음 - 완료로 처리"
    
    if job.repository.local_git_path && Dir.exist?(job.repository.local_git_path)
      # Git 저장소 정보
      Dir.chdir(job.repository.local_git_path) do
        commit_count = `git rev-list --all --count 2>/dev/null`.strip
        puts "  Git 저장소: #{commit_count} 커밋"
      end
      
      # 완료 처리
      job.update!(
        status: 'completed',
        completed_at: Time.current,
        progress: 100
      )
      puts "  => completed로 변경"
    else
      puts "  Git 저장소가 없음"
    end
  else
    puts "  git-svn 아직 실행 중 (PID: #{git_svn_pid})"
    
    # 강제 종료
    puts "  프로세스 종료 중..."
    `kill -TERM #{git_svn_pid} 2>/dev/null`
    sleep 2
    
    # 완료 처리
    job.update!(
      status: 'completed',
      completed_at: Time.current,
      progress: 100
    )
    puts "  => 강제 완료 처리"
  end
end

puts "\n완료된 작업들:"
Job.where(status: 'completed').each do |job|
  puts "- Job ##{job.id}: #{job.repository.name}"
end