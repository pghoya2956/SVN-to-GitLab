require_relative 'concerns/progress_trackable'

class MigrationJob
  include Sidekiq::Job
  include ProgressTrackable
  
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
  
  def perform(job_id)
    @job = Job.find(job_id)
    @repository = @job.repository
    @user = @job.user
    @start_time = Time.current
    
    # Set current user for default scope
    User.current = @user
    
    begin
      @job.mark_as_running!
      @job.append_output("Starting SVN to GitLab migration with git-svn...")
      
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
      @job.append_output("Saved local git path for incremental sync")
      
      @job.mark_as_completed!(gitlab_url)
      @job.append_output("Migration completed successfully!")
      
    rescue => e
      @job.mark_as_failed!(e.message)
      raise e
    ensure
      User.current = nil
    end
  end
  
  private
  
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
    @job.append_output("Cloning SVN repository with git-svn...")
    @job.update(progress: 20)
    
    # Use persistent directory for git repos
    git_repos_dir = Rails.root.join('git_repos', "repository_#{@repository.id}")
    FileUtils.mkdir_p(git_repos_dir)
    
    git_path = git_repos_dir.join('git_repo')
    
    # 기존 디렉토리가 있으면 삭제 (재시작 시)
    if File.directory?(git_path)
      FileUtils.rm_rf(git_path)
      @job.append_output("Removed existing git repository directory")
    end
    
    # 즉시 local_git_path 저장 (진행률 추적용)
    @repository.update!(local_git_path: git_path.to_s)
    
    # Build git svn clone command
    cmd = build_git_svn_command(git_path)
    
    # Execute git svn clone
    execute_git_svn_clone(cmd, git_path)
    
    git_path.to_s
  end
  
  def build_git_svn_command(target_path)
    cmd = ['git', 'svn', 'clone']
    
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
end