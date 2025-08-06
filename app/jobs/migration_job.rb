require_relative 'concerns/progress_trackable'
require_relative 'concerns/resumable_errors'

class MigrationJob
  include Sidekiq::Job
  include ProgressTrackable
  include ResumableErrors
  
  sidekiq_options retry: false  # 자동 재시도 비활성화 (수동 재개 사용)
  
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
  
  def perform(job_id, gitlab_token = nil, gitlab_endpoint = nil)
    @job = Job.find(job_id)
    @repository = @job.repository
    @gitlab_token = gitlab_token
    @gitlab_endpoint = gitlab_endpoint || 'https://gitlab.com/api/v4'
    @start_time = Time.current
    
    begin
      # GitLab 토큰 검증 (테스트 모드에서는 건너뛰기)
      unless ENV['SKIP_GITLAB_VALIDATION'] == 'true'
        validate_gitlab_token!
      end
      
      # 재개 여부 확인
      if should_resume?
        resume_migration
      else
        start_fresh_migration
      end
      
    rescue => e
      Rails.logger.error "MigrationJob Error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # 에러 분류 및 재개 가능 여부 설정
      handle_job_error(e) rescue nil
      
      # 상세한 에러 정보 저장
      error_details = {
        message: e.message,
        phase: @job.phase,
        progress: @job.progress,
        current_revision: @job.current_revision,
        backtrace: e.backtrace.first(5)
      }
      
      @job.append_error("Error Details: #{error_details.to_json}")
      @job.mark_as_failed!(e.message)
      
      # 재개 가능한 에러인 경우 체크포인트 저장
      if is_resumable_error?(e)
        @job.save_checkpoint!(
          error: e.message,
          failed_at: Time.current
        )
        @job.update(resumable: true)
      end
      
      raise e
    end
  end
  
  private
  
  def should_resume?
    @job.phase != 'pending' && 
    @job.checkpoint_data.present? &&
    @repository.local_git_path.present?
  end
  
  def resume_migration
    @job.start_resume!
    @job.append_output("이전 작업을 재개합니다...")
    @job.append_output("마지막 체크포인트: #{@job.checkpoint_data['timestamp']}")
    
    # 진행률 추적 재시작
    track_progress
    
    case @job.phase
    when 'cloning'
      resume_cloning
    when 'applying_strategy'
      resume_applying_strategy
    when 'pushing'
      resume_pushing
    else
      # 알 수 없는 단계면 처음부터
      start_fresh_migration
    end
  end
  
  def start_fresh_migration
    @job.mark_as_running!
    @job.update_phase!('pending')
    
    migration_mode = @repository.migration_method == 'simple' ? 'Simple (latest revision only)' : 'Full History'
    @job.append_output("Starting SVN to GitLab migration with git-svn (#{migration_mode} mode)...")
    
    # 진행률 추적 시작
    track_progress
    
    # Step 1: Validate repository access
    validate_repository!
    
    # Step 2: Clone SVN repository with git-svn (이력 보존)
    git_path = clone_svn_repository
    
    # Step 3: Apply migration strategy (simplified)
    apply_migration_strategy(git_path)
    
    # Step 4: Push to GitLab
    gitlab_url = push_to_gitlab(git_path)
    
    # Step 5: Save git path for incremental sync
    @repository.update!(local_git_path: git_path)
    
    @job.mark_as_completed!(gitlab_url)
    @job.update_phase!('completed')
    @job.append_output("Migration completed successfully!")
    @job.append_output("GitLab repository: #{gitlab_url}")
  end
  
  def get_svn_info
    cmd = ['svn', 'info', @repository.svn_url]
    
    if @repository.auth_type == 'basic'
      cmd += ['--username', @repository.username] if @repository.username.present?
      cmd += ['--password', @repository.password] if @repository.password.present?
      cmd << '--non-interactive'
      cmd << '--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other'
    end
    
    output = []
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      output = stdout.read
      unless wait_thr.value.success?
        Rails.logger.warn "Could not get SVN info: #{stderr.read}"
        return
      end
    end
    
    # Parse revision number
    if output =~ /Revision:\s+(\d+)/
      total_revisions = $1.to_i
      @job.update(total_revisions: total_revisions)
      @job.append_output("Total revisions in repository: #{total_revisions}")
    end
  rescue => e
    Rails.logger.warn "Error getting SVN info: #{e.message}"
  end
  
  def validate_repository!
    @job.append_output("Validating SVN repository access...")
    @job.update(progress: 10)  # 10% for validation
    
    validator = Repositories::ValidatorService.new(@repository)
    result = validator.call
    
    unless result[:success]
      raise "Repository validation failed: #{result[:errors].join(', ')}"
    end
    
    @job.append_output("Repository validated successfully")
  end
  
  def clone_svn_repository
    @job.update_phase!('cloning')
    
    if @repository.migration_method == 'simple'
      @job.append_output("Cloning SVN repository (Simple mode - latest revision only)...")
    else
      @job.append_output("Cloning SVN repository with git-svn (Full history mode)...")
      # Get total revision count for accurate progress tracking
      get_svn_info
    end
    @job.update(progress: 20)
    
    # 체크포인트 저장
    @job.save_checkpoint!(phase: 'cloning')
    
    # Use persistent directory for git repos
    git_repos_dir = Rails.root.join('git_repos', "repository_#{@repository.id}")
    FileUtils.mkdir_p(git_repos_dir)
    
    git_path = git_repos_dir.join('git_repo')
    
    # 재개 가능한 경우 기존 디렉토리 유지
    should_continue_existing = false
    
    if File.directory?(git_path) && File.exist?("#{git_path}/.git/svn")
      # 실제로 커밋이 있는지 확인
      if has_git_commits?(git_path)
        @job.append_output("기존 git-svn 저장소를 발견했습니다. 이어서 진행합니다...")
        
        # 즉시 local_git_path 저장
        @repository.update!(local_git_path: git_path.to_s)
        
        # git svn fetch로 이어서 진행
        execute_git_svn_fetch(git_path)
        should_continue_existing = true
      else
        # git-svn 메타데이터는 있지만 커밋이 없는 경우 - 체크포인트 확인
        last_checkpoint_rev = @job.checkpoint_data['last_fetched_revision'] || 0
        if last_checkpoint_rev > 0
          @job.append_output("체크포인트 발견: r#{last_checkpoint_rev}부터 이어서 진행합니다.")
          @job.update!(current_revision: last_checkpoint_rev)
          # 배치 fetch로 이어서 진행
          execute_batch_fetch(git_path, last_checkpoint_rev + 1)
          should_continue_existing = true
        else
          @job.append_output("git-svn 초기화는 되었지만 리비전이 없습니다. 처음부터 fetch합니다.")
          execute_batch_fetch(git_path, 1)
          should_continue_existing = true
        end
      end
    elsif File.directory?(git_path)
      # git-svn 메타데이터가 없는 경우 또는 .git 디렉토리만 있는 경우
      FileUtils.rm_rf(git_path)
      @job.append_output("기존 디렉토리 제거 (git-svn 메타데이터 없음)")
    end
    
    # 새로 시작해야 하는 경우
    unless should_continue_existing
      # 즉시 local_git_path 저장 (진행률 추적용)
      @repository.update!(local_git_path: git_path.to_s)
      
      # git svn init으로 초기화
      execute_git_svn_init(git_path)
      
      # 배치 fetch로 리비전 가져오기
      execute_batch_fetch(git_path, 1)
    end
    
    git_path.to_s
  end
  
  def execute_git_svn_init(git_path)
    @job.append_output("Initializing git-svn repository...")
    
    FileUtils.mkdir_p(git_path.to_s)
    
    Dir.chdir(git_path.to_s) do
      # git init first
      system('git', 'init')
      
      # git svn init with options
      cmd = ['git', 'svn', 'init']
      
      # SVN 레이아웃 옵션
      if @repository.svn_url.include?('/trunk') || @repository.svn_url.include?('/branches/') || @repository.svn_url.include?('/tags/')
        @job.append_output("SVN URL already contains specific path, skipping layout options")
      elsif @repository.standard_layout?
        cmd << '--stdlayout'
      elsif @repository.trunk? || @repository.branches? || @repository.tags?
        cmd += ['--trunk', @repository.trunk_path] if @repository.trunk?
        cmd += ['--branches', @repository.branches_path] if @repository.branches?
        cmd += ['--tags', @repository.tags_path] if @repository.tags?
      end
      
      # 메타데이터 포함 (리비전 추적을 위해 필요)
      # --no-metadata를 사용하면 재개 기능이 작동하지 않음
      
      # Authors 파일은 fetch 단계에서 사용 (init에서는 지원하지 않음)
      
      # SVN URL
      cmd << @repository.svn_url
      
      # Execute init
      output = `#{cmd.join(' ')} 2>&1`
      unless $?.success?
        raise "git svn init failed: #{output}"
      end
      
      @job.append_output("git-svn repository initialized successfully")
    end
  end
  
  def execute_batch_fetch(git_path, start_revision)
    @job.append_output("Starting batch fetch from revision #{start_revision}...")
    
    # 배치 크기 설정 (한 번에 가져올 리비전 수)
    batch_size = ENV.fetch('SVN_BATCH_SIZE', 100).to_i
    
    Dir.chdir(git_path.to_s) do
      current_rev = start_revision
      
      while current_rev <= (@job.total_revisions || Float::INFINITY)
        end_rev = [current_rev + batch_size - 1, @job.total_revisions].compact.min
        
        @job.append_output("Fetching revisions #{current_rev} to #{end_rev}...")
        
        # git svn fetch with revision range
        cmd = if @repository.migration_method == 'simple'
                ['git', 'svn', 'fetch', '-r', "HEAD"]
              else
                ['git', 'svn', 'fetch', '-r', "#{current_rev}:#{end_rev}"]
              end
        
        # Authors 파일 추가
        authors_file = create_authors_file
        if authors_file && File.exist?(authors_file)
          cmd += ['--authors-file', authors_file]
        end
        
        success = false
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
          # 패스워드 처리
          if @repository.auth_type == 'basic' && @repository.password.present?
            stdin.puts @repository.password
            stdin.close
          end
          
          stdout.each_line do |line|
            @job.append_output("git-svn: #{line.strip}")
            update_progress_from_git_svn(line)
          end
          
          stderr.each_line do |line|
            @job.append_output("git-svn: #{line.strip}")
          end
          
          success = wait_thr.value.success?
        end
        
        unless success
          @job.append_error("Batch fetch failed at revision #{current_rev}-#{end_rev}")
          
          # 실제로 가져온 마지막 리비전 확인
          last_fetched = get_last_fetched_revision(git_path)
          
          if last_fetched > 0
            # 일부라도 성공했으면 그 지점을 저장
            @job.append_output("Partial success: fetched up to revision #{last_fetched}")
            save_batch_checkpoint(last_fetched)
          else
            # 아무것도 못 가져왔으면 체크포인트 저장하지 않음 (처음부터 다시)
            @job.append_output("No revisions fetched in this batch, will retry from beginning")
          end
          
          # Job 상태를 failed로 변경
          @job.update!(status: 'failed', phase: 'cloning')
          raise "Batch fetch failed"
        end
        
        # 배치 완료 후 체크포인트 저장
        save_batch_checkpoint(end_rev)
        
        # Simple mode는 한 번만 실행
        break if @repository.migration_method == 'simple'
        
        # 다음 배치
        current_rev = end_rev + 1
        
        # 완료 확인
        if @job.total_revisions && current_rev > @job.total_revisions
          @job.append_output("All revisions fetched successfully!")
          break
        end
      end
    rescue => e
      # 배치 처리 중 오류 발생 시 Job 상태 업데이트
      @job.update!(status: 'failed', phase: 'cloning')
      raise e
    end
    
    @job.update(progress: 70)
  end
  
  def save_batch_checkpoint(last_revision)
    @job.save_checkpoint!(
      phase: 'cloning',
      last_fetched_revision: last_revision
    )
    @job.append_output("Checkpoint saved at revision #{last_revision}")
  end
  
  def build_git_svn_command(target_path)
    cmd = ['git', 'svn', 'clone']
    
    # Simple mode: 최신 리비전만 가져오기
    if @repository.migration_method == 'simple'
      cmd += ['-r', 'HEAD']
      @job.append_output("Using simple mode: fetching only the latest revision")
    else
      @job.append_output("Using full mode: fetching entire commit history")
    end
    
    # SVN 레이아웃 옵션
    # SVN URL이 이미 trunk/branches/tags를 포함하는 경우 레이아웃 옵션을 사용하지 않음
    if @repository.svn_url.include?('/trunk') || @repository.svn_url.include?('/branches/') || @repository.svn_url.include?('/tags/')
      @job.append_output("SVN URL already contains specific path, skipping layout options")
    elsif @repository.standard_layout?
      cmd << '--stdlayout'
    elsif @repository.trunk? || @repository.branches? || @repository.tags?
      # 커스텀 레이아웃
      cmd += ['--trunk', @repository.trunk_path] if @repository.trunk?
      cmd += ['--branches', @repository.branches_path] if @repository.branches?
      cmd += ['--tags', @repository.tags_path] if @repository.tags?
    end
    
    # Authors 파일
    authors_file = create_authors_file
    if authors_file
      cmd += ['--authors-file', authors_file]
      @job.append_output("Using authors file with #{@repository.authors_mapping&.size || 0} mappings")
    else
      @job.append_output("Proceeding without authors file (will use SVN usernames)")
    end
    
    # 메타데이터 제거 옵션
    cmd << '--no-metadata'
    
    # Prefix 설정
    cmd += ['--prefix', 'origin/']
    
    # 인증 정보
    if @repository.auth_type == 'basic' && @repository.username.present?
      cmd += ['--username', @repository.username]
    end
    
    # 진행률 표시 (git svn은 --verbose를 지원하지 않음)
    
    # URL과 대상 경로
    cmd << @repository.svn_url
    cmd << target_path.to_s
    
    cmd
  end
  
  def execute_git_svn_clone(cmd, git_path)
    stdout_buffer = []
    stderr_buffer = []
    
    begin
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        # 패스워드 처리
        if @repository.auth_type == 'basic' && @repository.password.present?
          stdin.puts @repository.password
          stdin.close
        end
        
        # stdout과 stderr를 동시에 읽기 위한 스레드
        stdout_thread = Thread.new do
          stdout.each_line do |line|
            stdout_buffer << line
            @job.append_output("git-svn: #{line.strip}")
            update_progress_from_git_svn(line)
          end
        end
        
        stderr_thread = Thread.new do
          stderr.each_line do |line|
            stderr_buffer << line
            # hint 메시지는 정보성이므로 output으로 처리
            if line.include?('hint:') || line.include?('Initialized empty Git repository')
              @job.append_output("git-svn: #{line.strip}")
            else
              @job.append_output("git-svn: #{line.strip}")
            end
          end
        end
        
        stdout_thread.join
        stderr_thread.join
        
        unless wait_thr.value.success?
          error_output = stderr_buffer.join
          @job.append_error("git svn clone failed with exit code: #{wait_thr.value.exitstatus}")
          @job.append_error("Error output: #{error_output}") if error_output.present? && !error_output.include?('hint:')
          
          # 실패 시 git 디렉토리 정리
          if File.directory?(git_path.to_s)
            FileUtils.rm_rf(git_path.to_s)
            @job.append_output("Failed clone attempt - cleaned up #{git_path}")
          end
          
          raise "git svn clone failed: #{error_output}"
        end
      end
    rescue => e
      # 에러 발생 시 디렉토리 정리
      if File.directory?(git_path.to_s)
        FileUtils.rm_rf(git_path.to_s)
        @job.append_output("Error occurred - cleaned up #{git_path}")
      end
      raise e
    end
    
    @job.update(progress: 70)
  end
  
  
  def execute_git_svn_fetch(git_path)
    # Ensure git_path is a string
    git_path_str = git_path.to_s
    
    Dir.chdir(git_path_str) do
      # 현재 상태 확인
      last_rev = get_last_fetched_revision(git_path)
      @job.append_output("마지막으로 가져온 리비전: r#{last_rev}")
      
      # git svn fetch 실행
      cmd = ['git', 'svn', 'fetch']
      
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
          @job.append_output("git-svn: #{line.strip}")
          update_progress_from_git_svn(line)
        end
        
        stderr.each_line do |line|
          @job.append_output("git-svn: #{line.strip}")
        end
        
        unless wait_thr.value.success?
          error_output = stderr.read if stderr
          @job.append_error("git svn fetch failed: #{error_output}")
          raise "git svn fetch failed: #{error_output}"
        end
      end
    end
    
    @job.update(progress: 70)
  end
  
  def get_last_fetched_revision(git_path)
    git_path_str = git_path.to_s
    
    Dir.chdir(git_path_str) do
      # git log로 마지막 커밋의 SVN 리비전 확인
      output = `git log -1 --format=%B 2>/dev/null | grep -oP 'git-svn-id:.*@\\K[0-9]+' | head -1`.strip
      
      if output.empty?
        # git svn info로 시도
        output = `git svn info 2>/dev/null | grep 'Last Changed Rev' | awk '{print $4}'`.strip
      end
      
      if output.empty?
        # 체크포인트에서 확인
        return @job.checkpoint_data['last_fetched_revision'] || 0
      end
      
      output.to_i
    end
  rescue => e
    @job.append_output("Failed to get last revision: #{e.message}")
    @job.checkpoint_data['last_fetched_revision'] || 0
  end
  
  def update_progress_from_git_svn(line)
    # r1234 = abc123... 형식의 출력 파싱
    if line =~ /^r(\d+) = ([a-f0-9]+)/
      revision = $1.to_i
      commit_hash = $2
      
      # 리비전 업데이트 (항상 최신 리비전 유지)
      @job.update!(current_revision: revision)
      
      # 진행률 계산 및 업데이트
      if @job.total_revisions.present? && @job.total_revisions > 0
        # Clone phase is from 20% to 70% (50% of total progress)
        clone_progress = (revision.to_f / @job.total_revisions * 50).to_i
        total_progress = 20 + clone_progress  # 20% base + clone progress
        
        # 진행률이 후퇴하지 않도록 보장
        current_progress = @job.progress || 0
        if total_progress > current_progress
          @job.update(progress: [total_progress, 70].min)
        end
        
        # 처리 속도 계산 (매 10개 리비전마다)
        if revision % 10 == 0 && @job.started_at.present?
          elapsed_seconds = Time.current - @job.started_at
          if elapsed_seconds > 0
            speed = revision.to_f / elapsed_seconds
            @job.update(processing_speed: speed.round(2))
            
            # ETA 계산
            if speed > 0
              remaining_revisions = @job.total_revisions - revision
              eta_seconds = remaining_revisions / speed
              @job.update(
                estimated_completion_at: Time.current + eta_seconds.seconds,
                eta_seconds: eta_seconds.round
              )
            end
          end
        end
        
        # 100개 리비전마다 체크포인트 저장
        if revision % 100 == 0
          @job.save_checkpoint!(
            last_processed_revision: revision,
            last_commit_hash: commit_hash
          )
        end
        
        # ActionCable로 진행률 브로드캐스트 (매 5개 리비전마다)
        if revision % 5 == 0
          progress_data = {
            progress_percentage: @job.progress_percentage,
            current_revision: @job.current_revision,
            total_revisions: @job.total_revisions,
            processing_speed: @job.processing_speed,
            eta: @job.eta_seconds
          }
          broadcast_progress(progress_data)
        end
      else
        # 전체 리비전 수를 모르는 경우 진행률 추정
        @job.update_progress!
      end
    elsif line.include?("Checked out HEAD")
      # 체크아웃 완료 시 70%로 설정
      @job.update(progress: 70)
    elsif line.include?("Importing revision") || line.include?("Fetching revision")
      # SVN 리비전 가져오는 중 메시지 파싱
      if line =~ /revision (\d+)/
        revision = $1.to_i
        @job.update!(current_revision: revision) if revision > (@job.current_revision || 0)
      end
    end
  end
  
  def apply_migration_strategy(git_path)
    @job.update_phase!('applying_strategy')
    @job.append_output("Applying migration strategy...")
    @job.update(progress: 75)
    
    # 체크포인트 저장
    @job.save_checkpoint!(phase: 'applying_strategy')
    
    # Ensure git_path is a string
    git_path_str = git_path.to_s
    
    Dir.chdir(git_path_str) do
      # main 브랜치로 이름 변경
      system('git', 'branch', '-m', 'master', 'main') if `git branch --show-current`.strip == 'master'
      
      # Git LFS 설정 (필요한 경우)
      if @repository.large_file_handling == 'git-lfs'
        setup_git_lfs(git_path)
      end
      
      # .gitignore 추가 (필요한 경우)
      apply_ignore_patterns(git_path)
    end
    
    @job.append_output("Migration strategy applied")
  end
  
  def apply_ignore_patterns(git_path)
    return unless @repository.ignore_patterns.present?
    
    gitignore_path = File.join(git_path, '.gitignore')
    File.open(gitignore_path, 'a') do |f|
      f.puts "\n# Patterns from migration configuration"
      f.puts @repository.ignore_patterns
    end
    
    # Commit .gitignore if added
    Dir.chdir(git_path) do
      system('git', 'add', '.gitignore')
      _, _, status = Open3.capture3('git', 'diff', '--cached', '--quiet')
      unless status.success?
        system('git', 'commit', '-m', 'Add .gitignore from migration configuration')
      end
    end
  end
  
  
  def setup_git_lfs(git_path)
    @job.append_output("Setting up Git LFS...")
    
    execute_command('git lfs install', git_path)
    
    # Track large files
    extensions = %w[zip tar gz bz2 7z rar exe dmg iso jar war ear]
    extensions.each do |ext|
      execute_command("git lfs track '*.#{ext}'", git_path)
    end
    
    # Track files over size limit
    max_size = @repository.max_file_size_mb || 100
    execute_command("git lfs track '*.{*}' --above=#{max_size}mb", git_path)
    
    execute_command('git add .gitattributes', git_path)
    # Check if there are changes to commit
    _, _, status = Open3.capture3('git diff --cached --quiet', chdir: git_path)
    unless status.success?
      execute_command(['git', 'commit', '-m', 'Configure Git LFS'], git_path)
    end
  end
  
  def push_to_gitlab(git_path)
    @job.update_phase!('pushing')
    @job.append_output("Pushing to GitLab...")
    @job.update(progress: 80)
    
    # 체크포인트 저장
    @job.save_checkpoint!(phase: 'pushing')
    
    # Get GitLab project details
    connector = Repositories::GitlabConnector.new(@gitlab_token, @gitlab_endpoint)
    project = connector.fetch_project(@repository.gitlab_project_id)
    
    unless project[:success]
      raise "Failed to fetch GitLab project: #{project[:errors].join(', ')}"
    end
    
    gitlab_url = project[:project][:http_url_to_repo]
    
    # Ensure git_path is a string
    git_path_str = git_path.to_s
    
    Dir.chdir(git_path_str) do
      # Add GitLab remote
      system('git', 'remote', 'add', 'gitlab', gitlab_url)
      
      # Push with authentication
      push_url = gitlab_url.sub('https://', "https://oauth2:#{@gitlab_token}@")
      
      # Push with authentication
      push_success = false
      push_errors = []
      
      Open3.popen3('git', 'push', '-u', push_url, '--all') do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| @job.append_output("Push: #{line.strip}") }
        stderr.each_line do |line| 
          @job.append_output("Push: #{line.strip}")
          push_errors << line
        end
        
        if wait_thr.value.success?
          push_success = true
        else
          # 에러 분석
          error_text = push_errors.join(' ')
          
          if error_text.include?('401') || error_text.include?('Authentication failed') || 
             error_text.include?('Unauthorized') || error_text.include?('invalid credentials')
            # 토큰 문제
            error_msg = "GitLab authentication failed. Please check your Personal Access Token."
            @job.append_error(error_msg)
            @job.update(resumable: false)  # 토큰 에러는 재개 불가능
            raise error_msg
          else
            # 일반 push 실패 - force push 시도
            @job.append_output("Normal push failed, trying force push...")
            system('git', 'push', '-u', '--force', push_url, '--all')
          end
        end
      end
      
      # 태그 푸시
      if @repository.tags?
        @job.append_output("Pushing tags...")
        system('git', 'push', push_url, '--tags')
      end
    end
    
    @job.update(progress: 100)
    project[:project][:web_url]
  end
  
  
  
  def execute_command(cmd, working_dir = nil)
    if cmd.is_a?(String)
      # For simple string commands
      if working_dir
        system(cmd, chdir: working_dir)
      else
        system(cmd)
      end
    else
      # For array commands
      if working_dir
        system(*cmd, chdir: working_dir)
      else
        system(*cmd)
      end
    end
  end
  
  def create_authors_file
    # For full history mode, extract all authors first
    if @repository.migration_method != 'simple' && (@repository.authors_mapping.blank? || @repository.authors_mapping.empty?)
      @job.append_output("Extracting all authors from SVN repository...")
      extractor = Repositories::AuthorsExtractor.new(@repository)
      
      begin
        authors = extractor.extract_all_authors
        if authors.any?
          @job.append_output("Found #{authors.size} unique authors in SVN history")
          # Save extracted authors for future reference
          @repository.update(authors_mapping: authors.map { |a| 
            { 'svn_name' => a, 'git_name' => a, 'git_email' => "#{a.gsub(/[^a-zA-Z0-9]/, '')}@example.com" }
          })
        end
      rescue => e
        @job.append_output("Warning: Could not extract authors: #{e.message}")
        # Continue without authors file for full mode to avoid failures
        return nil
      end
    end
    
    return nil unless @repository.authors_mapping.present? && @repository.authors_mapping.any?
    
    # Create temporary authors file
    temp_dir = Rails.root.join('tmp', 'migrations', @job.id.to_s)
    FileUtils.mkdir_p(temp_dir)
    
    authors_file_path = temp_dir.join('authors.txt')
    
    File.open(authors_file_path, 'w') do |file|
      @repository.authors_mapping.each do |author|
        file.puts "#{author['svn_name']} = #{author['git_name']} <#{author['git_email']}>"
      end
    end
    
    @job.append_output("Created authors file with #{@repository.authors_mapping.size} mappings")
    authors_file_path.to_s
  end
  
  # 재개 메서드들
  def resume_cloning
    @job.append_output("Clone 단계에서 재개합니다...")
    
    git_path = @repository.local_git_path
    
    # 디렉토리가 존재하고 git-svn 메타데이터가 있는 경우
    if git_path && File.exist?(git_path) && File.exist?("#{git_path}/.git/svn")
      # git svn fetch로 이어서 진행
      execute_git_svn_fetch(git_path)
      
      # 다음 단계로
      apply_migration_strategy(git_path)
      push_to_gitlab(git_path)
      
      @job.mark_as_completed!(@repository.gitlab_project_url)
      @job.update_phase!('completed')
    else
      # 디렉토리가 없거나 git-svn이 없으면 clone 단계부터 다시
      @job.append_output("git-svn 저장소가 없습니다. Clone 단계부터 다시 시작합니다.")
      
      # Clone 단계 재실행
      git_path = clone_svn_repository
      
      # 다음 단계로
      apply_migration_strategy(git_path)
      gitlab_url = push_to_gitlab(git_path)
      
      @job.mark_as_completed!(gitlab_url)
      @job.update_phase!('completed')
    end
  end
  
  def resume_applying_strategy
    @job.append_output("전략 적용 단계에서 재개합니다...")
    
    git_path = @repository.local_git_path
    
    # 전략 적용 계속
    apply_migration_strategy(git_path)
    
    # 다음 단계
    push_to_gitlab(git_path)
    
    @job.mark_as_completed!(@repository.gitlab_project_url)
    @job.update_phase!('completed')
  end
  
  def resume_pushing
    @job.append_output("Push 단계에서 재개합니다...")
    
    git_path = @repository.local_git_path
    
    # Push 재시도
    gitlab_url = push_to_gitlab(git_path)
    
    @job.mark_as_completed!(gitlab_url)
    @job.update_phase!('completed')
  end
  
  private
  
  def validate_gitlab_token!
    return if @gitlab_token.blank?
    
    @job.append_output("Validating GitLab token...")
    
    connector = Repositories::GitlabConnector.new(@gitlab_token, @gitlab_endpoint)
    result = connector.validate_connection
    
    unless result[:success]
      error_msg = "GitLab token validation failed: #{result[:errors].join(', ')}"
      @job.append_error(error_msg)
      @job.mark_as_failed!(error_msg)
      
      # 토큰 에러는 재개 불가능
      @job.update(resumable: false)
      
      raise error_msg
    end
    
    @job.append_output("GitLab token validated successfully (User: #{result[:user][:username]})")
  end
  
  def is_resumable_error?(error)
    # 네트워크 에러, 타임아웃 등은 재개 가능
    resumable_errors = [
      'Network',
      'Timeout',
      'Connection reset',
      'Connection refused',
      'authentication failed',
      'temporary failure',
      'git svn fetch failed'
    ]
    
    resumable_errors.any? { |pattern| error.message.include?(pattern) }
  end
  
  def has_git_commits?(git_path)
    # Ensure git_path is a string
    git_path_str = git_path.to_s
    
    Dir.chdir(git_path_str) do
      # git rev-list로 커밋이 있는지 확인 (더 정확한 방법)
      result = `git rev-list --all --count 2>/dev/null`
      count = result.strip.to_i
      @job.append_output("현재 저장소의 커밋 수: #{count}개") if @job
      count > 0
    end
  rescue => e
    @job.append_output("커밋 확인 중 오류: #{e.message}") if @job
    false
  end
end