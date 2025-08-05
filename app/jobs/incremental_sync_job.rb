class IncrementalSyncJob
  include Sidekiq::Job
  
  sidekiq_options retry: 3, dead: false
  
  sidekiq_retry_in do |count, exception|
    case count
    when 0
      60 # 1 minute
    when 1
      300 # 5 minutes
    when 2
      600 # 10 minutes
    end
  end
  
  def perform(repository_id)
    @repository = Repository.find(repository_id)
    @user = @repository.user
    
    User.current = @user
    
    # 동시 실행 방지
    return if @repository.has_active_sync_job?
    
    @job = @repository.jobs.create!(
      user: @user,
      job_type: 'incremental_sync',
      status: 'pending',
      parent_job_id: @repository.last_migration_job&.id,
      parameters: { 
        repository_id: repository_id,
        last_synced_revision: @repository.last_synced_revision
      }.to_json
    )
    
    begin
      @job.mark_as_running!
      @job.append_output("Starting incremental sync with git-svn...")
      
      perform_incremental_sync
      
      @job.mark_as_completed!
      @job.append_output("Incremental sync completed successfully!")
      
    rescue => e
      @job.mark_as_failed!(e.message)
      raise e
    ensure
      User.current = nil
    end
  end
  
  private
  
  def perform_incremental_sync
    validate_git_svn_repository!
    
    git_dir = @repository.local_git_path
    
    Dir.chdir(git_dir) do
      # 1. 현재 상태 저장
      save_current_state
      
      # 2. SVN에서 새 커밋 가져오기
      fetch_new_commits
      
      # 3. GitLab에 푸시
      push_to_gitlab
      
      # 4. 동기화 정보 업데이트
      update_sync_info
    end
  end
  
  def validate_git_svn_repository!
    unless @repository.local_git_path.present? && File.directory?(@repository.local_git_path)
      raise "Local git repository not found. Please run migration first."
    end
    
    # git-svn 저장소인지 확인
    git_dir = @repository.local_git_path
    Dir.chdir(git_dir) do
      unless File.exist?('.git/svn')
        raise "Not a git-svn repository. Please re-migrate with git-svn."
      end
    end
  end
  
  def save_current_state
    @current_branch = `git rev-parse --abbrev-ref HEAD`.strip
    @current_commit = `git rev-parse HEAD`.strip
    @job.append_output("Current branch: #{@current_branch}, commit: #{@current_commit[0..7]}")
  end
  
  def fetch_new_commits
    @job.append_output("Fetching new commits from SVN...")
    @job.update(progress: 20)
    
    # git svn fetch 실행
    Open3.popen3('git', 'svn', 'fetch') do |stdin, stdout, stderr, wait_thr|
      new_commits = 0
      last_revision = nil
      
      stdout.each_line do |line|
        @job.append_output("git-svn: #{line.strip}")
        
        # 새로운 리비전 파싱 (r1234 = commit_hash)
        if line =~ /^r(\d+) = ([a-f0-9]+)/
          last_revision = $1.to_i
          new_commits += 1
          
          @job.update(
            processed_commits: new_commits,
            current_revision: last_revision,
            progress: [20 + (new_commits * 5), 70].min
          )
        end
      end
      
      stderr.each_line do |line|
        @job.append_output("git-svn: #{line.strip}")
      end
      
      unless wait_thr.value.success?
        raise "git svn fetch failed"
      end
      
      if new_commits == 0
        @job.append_output("No new commits found")
      else
        @job.append_output("Fetched #{new_commits} new commits (up to r#{last_revision})")
        
        # 로컬 브랜치 업데이트 (rebase)
        rebase_local_branch
      end
    end
  end
  
  def rebase_local_branch
    @job.append_output("Rebasing local branch...")
    
    # git svn rebase로 로컬 브랜치 업데이트
    success = system('git', 'svn', 'rebase')
    
    unless success
      # Rebase 실패 시 abort하고 에러
      system('git', 'rebase', '--abort')
      raise "git svn rebase failed - manual intervention required"
    end
    
    @job.append_output("Rebase completed successfully")
  end
  
  def push_to_gitlab
    @job.append_output("Pushing to GitLab...")
    @job.update(progress: 80)
    
    connector = Repositories::GitlabConnector.new(@user.gitlab_token)
    project = connector.fetch_project(@repository.gitlab_project_id)
    
    unless project[:success]
      raise "Failed to fetch GitLab project: #{project[:errors].join(', ')}"
    end
    
    gitlab_url = project[:project][:http_url_to_repo]
    push_url = gitlab_url.sub('https://', "https://oauth2:#{@user.gitlab_token.decrypt_token}@")
    
    # 현재 브랜치 푸시
    Open3.popen3('git', 'push', push_url, @current_branch) do |stdin, stdout, stderr, wait_thr|
      stdout.each_line { |line| @job.append_output("Push: #{line.strip}") }
      stderr.each_line { |line| @job.append_output("Push: #{line.strip}") }
      
      unless wait_thr.value.success?
        # Force push 시도
        @job.append_output("Normal push failed, trying force push...")
        success = system('git', 'push', '--force', push_url, @current_branch)
        
        unless success
          raise "Failed to push to GitLab"
        end
      end
    end
    
    # 태그가 있으면 푸시
    if has_new_tags?
      @job.append_output("Pushing new tags...")
      system('git', 'push', push_url, '--tags')
    end
    
    @job.update(progress: 100)
  end
  
  def update_sync_info
    # 최신 SVN 리비전 가져오기
    latest_revision = get_latest_svn_revision
    
    @repository.update!(
      last_synced_at: Time.current,
      last_synced_revision: latest_revision
    )
    
    @job.update(
      end_revision: latest_revision,
      completed_at: Time.current
    )
    
    @job.append_output("Sync completed. Latest revision: r#{latest_revision}")
  end
  
  def get_latest_svn_revision
    # git log에서 최신 SVN 리비전 추출
    output = `git log -1 --grep='^git-svn-id:' --pretty=format:'%b'`
    
    if match = output.match(/git-svn-id:.*@(\d+)/)
      match[1].to_i
    else
      # git-svn 메타데이터가 없는 경우 git-svn info 사용
      info = `git svn info`
      if match = info.match(/Revision: (\d+)/)
        match[1].to_i
      else
        0
      end
    end
  end
  
  def has_new_tags?
    # 새로운 태그가 있는지 확인
    remote_tags = `git ls-remote --tags origin 2>/dev/null`.lines.count
    local_tags = `git tag -l`.lines.count
    
    remote_tags > local_tags
  end
  
end