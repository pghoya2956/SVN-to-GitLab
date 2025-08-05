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
  
  def perform(job_id)
    @job = Job.find(job_id)
    @repository = @job.repository
    @user = @job.user
    @start_time = Time.current
    
    # Set current user for default scope
    User.current = @user
    
    begin
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
      
      @job.mark_as_failed!(e.message)
      raise e
    ensure
      User.current = nil
    end
  end
  
  private
  
  def should_resume?
    @job.phase != 'pending' && 
    @job.checkpoint_data.present? &&
    @repository.local_git_path.present? &&
    File.exist?(@repository.local_git_path)
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
    end
    @job.update(progress: 20)
    
    # Use persistent directory for git repos
    git_repos_dir = Rails.root.join('git_repos', "repository_#{@repository.id}")
    FileUtils.mkdir_p(git_repos_dir)
    
    git_path = git_repos_dir.join('git_repo')
    
    # 재개 가능한 경우 기존 디렉토리 유지
    if File.directory?(git_path) && File.exist?("#{git_path}/.git/svn")
      # 실제로 커밋이 있는지 확인
      if has_git_commits?(git_path)
        @job.append_output("기존 git-svn 저장소를 발견했습니다. 이어서 진행합니다...")
        
        # 즉시 local_git_path 저장
        @repository.update!(local_git_path: git_path.to_s)
        
        # git svn fetch로 이어서 진행
        execute_git_svn_fetch(git_path)
      else
        # git-svn 메타데이터는 있지만 커밋이 없는 경우
        @job.append_output("git-svn 메타데이터는 있지만 커밋이 없습니다. 처음부터 다시 시작합니다.")
        FileUtils.rm_rf(git_path)
        # 아래의 새로 시작 로직으로 진행
      end
    else
      # 새로 시작
      if File.directory?(git_path)
        FileUtils.rm_rf(git_path)
        @job.append_output("기존 디렉토리 제거 (git-svn 메타데이터 없음)")
      end
      
      # 즉시 local_git_path 저장 (진행률 추적용)
      @repository.update!(local_git_path: git_path.to_s)
      
      # Build git svn clone command
      cmd = build_git_svn_command(git_path)
      
      # Execute git svn clone
      execute_git_svn_clone(cmd, git_path)
    end
    
    git_path.to_s
  end
  
  def build_git_svn_command(target_path)
    cmd = ['git', 'svn', 'clone']
    
    # Simple mode: 최신 리비전만 가져오기
    if @repository.migration_method == 'simple'
      cmd += ['-r', 'HEAD']
      @job.append_output("Using simple mode: fetching only the latest revision")
    end
    
    # SVN 레이아웃 옵션
    if @repository.standard_layout?
      cmd << '--stdlayout'
    else
      # 커스텀 레이아웃
      cmd += ['--trunk', @repository.trunk_path] if @repository.trunk?
      cmd += ['--branches', @repository.branches_path] if @repository.branches?
      cmd += ['--tags', @repository.tags_path] if @repository.tags?
    end
    
    # Authors 파일
    if @repository.authors_mapping.present? && @repository.authors_mapping.any?
      authors_file = create_authors_file
      cmd += ['--authors-file', authors_file] if authors_file
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
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      # 패스워드 처리
      if @repository.auth_type == 'basic' && @repository.password.present?
        stdin.puts @repository.password
        stdin.close
      end
      
      # 출력 처리
      stdout.each_line do |line|
        @job.append_output("git-svn: #{line.strip}")
        update_progress_from_git_svn(line)
      end
      
      stderr.each_line do |line|
        @job.append_output("git-svn: #{line.strip}")
      end
      
      unless wait_thr.value.success?
        error_output = stderr.read if stderr
        @job.append_error("git svn clone failed with exit code: #{wait_thr.value.exitstatus}")
        @job.append_error("Error output: #{error_output}") if error_output.present?
        raise "git svn clone failed: #{error_output}"
      end
    end
    
    @job.update(progress: 70)
  end
  
  
  def execute_git_svn_fetch(git_path)
    Dir.chdir(git_path) do
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
    Dir.chdir(git_path) do
      output = `git svn info 2>/dev/null | grep 'Last Changed Rev' | awk '{print $4}'`.strip
      output.empty? ? 0 : output.to_i
    end
  rescue
    0
  end
  
  def update_progress_from_git_svn(line)
    # r1234 = abc123... 형식의 출력 파싱
    if line =~ /^r(\d+) = ([a-f0-9]+)/
      revision = $1.to_i
      commit_hash = $2
      
      @job.update!(
        current_revision: revision
      )
      
      # 전체 리비전 수 업데이트 (첫 번째로 받은 리비전 기준)
      if @job.total_revisions.nil? || @job.total_revisions <= 1000
        # 첫 리비전을 기준으로 전체 수 추정
        estimated_total = revision * 30 # SVNBook은 대략 6000개 정도
        @job.update!(total_revisions: estimated_total)
      end
      
      # 진행률 업데이트
      @job.update_progress!
    end
  end
  
  def apply_migration_strategy(git_path)
    @job.update_phase!('applying_strategy')
    @job.append_output("Applying migration strategy...")
    @job.update(progress: 75)
    
    Dir.chdir(git_path) do
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
    
    # Get GitLab project details
    connector = Repositories::GitlabConnector.new(@user.gitlab_token)
    project = connector.fetch_project(@repository.gitlab_project_id)
    
    unless project[:success]
      raise "Failed to fetch GitLab project: #{project[:errors].join(', ')}"
    end
    
    gitlab_url = project[:project][:http_url_to_repo]
    
    Dir.chdir(git_path) do
      # Add GitLab remote
      system('git', 'remote', 'add', 'gitlab', gitlab_url)
      
      # Push with authentication
      push_url = gitlab_url.sub('https://', "https://oauth2:#{@user.gitlab_token.decrypt_token}@")
      
      # Push with authentication
      Open3.popen3('git', 'push', '-u', push_url, '--all') do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| @job.append_output("Push: #{line.strip}") }
        stderr.each_line { |line| @job.append_output("Push: #{line.strip}") }
        
        unless wait_thr.value.success?
          @job.append_output("Normal push failed, trying force push...")
          
          system('git', 'push', '-u', '--force', push_url, '--all')
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
    
    if File.exist?("#{git_path}/.git/svn")
      # git svn fetch로 이어서 진행
      execute_git_svn_fetch(git_path)
      
      # 다음 단계로
      apply_migration_strategy(git_path)
      push_to_gitlab(git_path)
      
      @job.mark_as_completed!(@repository.gitlab_project_url)
      @job.update_phase!('completed')
    else
      # git-svn이 없으면 처음부터
      @job.append_output("git-svn 메타데이터가 없습니다. 처음부터 다시 시작합니다.")
      start_fresh_migration
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
  
  def has_git_commits?(git_path)
    Dir.chdir(git_path) do
      # git log로 커밋이 있는지 확인
      result = `git log --oneline -1 2>/dev/null`
      !result.strip.empty?
    end
  rescue
    false
  end
end