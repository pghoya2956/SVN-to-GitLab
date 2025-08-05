# Job 14를 완료 처리하고 GitLab으로 push
job = Job.find(14)
repo = job.repository

puts "=== Job #14 GitLab Push ==="
puts "Repository: #{repo.name}"
puts "GitLab Project ID: #{repo.gitlab_project_id}"
puts "Local Git Path: #{repo.local_git_path}"

if repo.local_git_path && Dir.exist?(repo.local_git_path)
  Dir.chdir(repo.local_git_path) do
    # Git 저장소 정보
    commit_count = `git rev-list --all --count 2>/dev/null`.strip
    puts "Git 커밋 수: #{commit_count}"
    
    # Job 상태 업데이트
    job.update!(
      status: 'completed',
      completed_at: Time.current,
      progress: 100
    )
    puts "Job 상태: completed로 변경"
    
    # GitLab remote 추가
    gitlab_url = "https://gitlab.com/ghdi7662/sample.git"
    puts "\nGitLab URL: #{gitlab_url}"
    
    # 기존 remote 제거
    `git remote remove gitlab 2>/dev/null`
    
    # GitLab remote 추가
    `git remote add gitlab #{gitlab_url}`
    
    # 현재 브랜치 확인
    current_branch = `git branch --show-current`.strip
    puts "현재 브랜치: #{current_branch}"
    
    # main 브랜치로 변경
    if current_branch == 'master'
      `git branch -m master main`
      puts "브랜치 이름 변경: master -> main"
    end
    
    # Force push to GitLab
    puts "\nGitLab으로 force push 시작..."
    push_result = `git push gitlab main --force 2>&1`
    
    if $?.success?
      puts "✅ GitLab push 성공!"
      puts push_result
    else
      puts "❌ GitLab push 실패:"
      puts push_result
    end
  end
else
  puts "Git 저장소를 찾을 수 없습니다."
end