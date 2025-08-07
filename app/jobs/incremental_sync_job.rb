require 'open3'
require 'fileutils'

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
  
  def perform(repository_id, gitlab_token = nil, gitlab_endpoint = nil)
    @repository = Repository.find(repository_id)
    @gitlab_token = gitlab_token
    @gitlab_endpoint = gitlab_endpoint || 'https://gitlab.com/api/v4'
    
    # 동시 실행 방지
    if @repository.has_active_sync_job?
      Rails.logger.warn "IncrementalSyncJob: Active sync job already exists for repository #{repository_id}"
      return
    end
    
    @job = @repository.jobs.create!(
      owner_token_hash: Digest::SHA256.hexdigest(gitlab_token),
      job_type: 'incremental_sync',
      status: 'pending',
      parent_job_id: @repository.last_migration_job&.id,
      parameters: { 
        repository_id: repository_id,
        last_synced_revision: @repository.last_synced_revision
      }.to_json
    )
    
    begin
      Rails.logger.info "IncrementalSyncJob: Created job #{@job.id} for repository #{repository_id}"
      @job.mark_as_running!
      @job.append_output("Starting incremental sync with git-svn...")
      
      perform_incremental_sync
      
      @job.mark_as_completed!
      @job.append_output("Incremental sync completed successfully!")
      
    rescue => e
      Rails.logger.error "IncrementalSyncJob: Error for job #{@job&.id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      @job.mark_as_failed!(e.message) if @job
      raise e
    end
  end
  
  private
  
  def perform_incremental_sync
    # Simple migration은 증분 동기화 지원 안함
    if @repository.migration_method == 'simple'
      @job.append_output("Incremental sync is not supported for simple migration method.")
      @job.append_output("Please re-migrate with 'full_history' method to enable incremental sync.")
      raise "Incremental sync is not supported for simple migration method. Please re-migrate with 'full_history' method to enable incremental sync."
    end
    
    validate_git_svn_repository!
    
    # 최신 성공한 마이그레이션 Job의 디렉토리 사용
    git_dir = get_latest_migration_directory
    
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
    git_dir = get_latest_migration_directory
    
    unless git_dir && File.directory?(git_dir)
      # 디렉토리가 없으면 SVN에서 다시 clone
      @job.append_output("Local git repository not found. Re-cloning from SVN...")
      clone_from_svn
      return
    end
    
    # git-svn 저장소인지 확인
    git_dir = @repository.local_git_path
    Dir.chdir(git_dir) do
      unless File.exist?('.git/svn')
        raise "Not a git-svn repository. Please re-migrate with git-svn."
      end
    end
  end
  
  def clone_from_svn
    @job.append_output("Creating git-svn clone for incremental sync...")
    
    # 디렉토리 생성
    FileUtils.mkdir_p(File.dirname(@repository.local_git_path))
    
    # git svn clone 명령 구성
    cmd = ['git', 'svn', 'clone']
    
    # 인증 정보 추가
    if @repository.auth_type == 'basic' && @repository.username.present?
      cmd += ['--username', @repository.username]
    end
    
    # SVN 레이아웃 옵션 (단일 원천 사용)
    layout_options = @repository.git_svn_layout_options
    cmd += layout_options unless layout_options.empty?
    
    # authors 파일이 있으면 사용
    authors_file_path = Rails.root.join('tmp', 'authors', "repository_#{@repository.id}_authors.txt")
    if File.exist?(authors_file_path)
      cmd += ['--authors-file', authors_file_path.to_s]
    end
    
    # 마지막 동기화된 리비전부터 시작
    if @repository.last_synced_revision.present? && @repository.last_synced_revision > 0
      start_revision = [@repository.last_synced_revision - 100, 1].max  # 100개 이전부터 시작
      cmd += ['-r', "#{start_revision}:HEAD"]
    else
      # 최근 1000개 커밋만 가져오기 (빠른 복구를 위해)
      cmd += ['-r', 'HEAD~1000:HEAD']
    end
    
    cmd += [@repository.svn_url, @repository.local_git_path]
    
    # Clone 실행
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      # 비밀번호 입력이 필요한 경우
      if @repository.auth_type == 'basic' && @repository.password.present?
        stdin.puts @repository.password
        stdin.close
      end
      
      stdout.each_line { |line| @job.append_output("Clone: #{line.strip}") }
      stderr.each_line { |line| @job.append_output("Clone: #{line.strip}") }
      
      unless wait_thr.value.success?
        raise "Failed to clone from SVN"
      end
    end
    
    @job.append_output("Git-svn clone completed. Repository ready for incremental sync.")
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
    
    connector = Repositories::GitlabConnector.new(@gitlab_token, @gitlab_endpoint)
    project = connector.fetch_project(@repository.gitlab_project_id)
    
    unless project[:success]
      raise "Failed to fetch GitLab project: #{project[:errors].join(', ')}"
    end
    
    gitlab_url = project[:project][:http_url_to_repo]
    push_url = gitlab_url.sub('https://', "https://oauth2:#{@gitlab_token}@")
    
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
  
  def get_latest_migration_directory
    # 최신 성공한 마이그레이션 Job 찾기
    last_migration = @repository.jobs
                                .where(job_type: 'migration', status: 'completed')
                                .order(completed_at: :desc)
                                .first
    
    if last_migration && last_migration.checkpoint_data['git_path'].present?
      # 해당 Job의 디렉토리 사용
      path = last_migration.checkpoint_data['git_path']
      @job.append_output("Using migration job ##{last_migration.id} directory: #{path}")
      return path
    end
    
    # Fallback: Repository의 local_git_path 사용
    @repository.local_git_path
  end
  
end