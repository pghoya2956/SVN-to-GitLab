user = User.find_by(email: 'test@example.com')
job = Job.find(14)
repo = job.repository

puts "=== GitLab Push with Token ==="
puts "Repository: #{repo.name}"
puts "GitLab Project ID: #{repo.gitlab_project_id}"
puts "GitLab Token: #{user.gitlab_token&.decrypt_token ? '설정됨' : '없음'}"

if repo.local_git_path && Dir.exist?(repo.local_git_path)
  Dir.chdir(repo.local_git_path) do
    # Git 저장소 정보
    commit_count = `git rev-list --all --count 2>/dev/null`.strip
    puts "Git 커밋 수: #{commit_count}"
    
    # GitLab URL with token
    if user.gitlab_token && user.gitlab_token.decrypt_token.present?
      gitlab_url = "https://oauth2:#{user.gitlab_token.decrypt_token}@gitlab.com/ghdi7662/sample.git"
      puts "\nGitLab URL 준비 완료"
      
      # 기존 remote 제거
      `git remote remove gitlab 2>/dev/null`
      
      # GitLab remote 추가
      `git remote add gitlab #{gitlab_url}`
      
      # 현재 브랜치 확인
      current_branch = `git branch --show-current`.strip
      puts "현재 브랜치: #{current_branch}"
      
      # Force push to GitLab
      puts "\nGitLab으로 force push 시작..."
      push_result = `git push gitlab #{current_branch}:main --force 2>&1`
      
      if $?.success?
        puts "✅ GitLab push 성공!"
        puts push_result
        
        # Push 작업 생성
        push_job = repo.jobs.create!(
          user: user,
          job_type: 'gitlab_push',
          status: 'completed',
          completed_at: Time.current,
          progress: 100,
          output_log: "GitLab push completed successfully\n#{push_result}"
        )
        puts "\nPush job created: ##{push_job.id}"
      else
        puts "❌ GitLab push 실패:"
        puts push_result
      end
    else
      puts "GitLab 토큰이 없습니다!"
    end
  end
else
  puts "Git 저장소를 찾을 수 없습니다."
end