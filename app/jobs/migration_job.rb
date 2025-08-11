require_relative 'concerns/resumable_errors'

class MigrationJob
  include Sidekiq::Job
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
    
    # Set timezone to KST
    Time.zone = 'Asia/Seoul'
    @start_time = Time.zone.now
    
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
      cmd += ['--password', @repository.encrypted_password] if @repository.encrypted_password.present?
      cmd << '--non-interactive'
      cmd << '--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other'
    end
    
    output = []
    error_output = []
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      output = stdout.read
      error_output = stderr.read
      unless wait_thr.value.success?
        Rails.logger.warn "Could not get SVN info: #{error_output}"
        @job.append_output("Warning: Could not get SVN info - #{error_output.split("\n").first}")
        return
      end
    end
    
    # Parse revision number
    if output =~ /Revision:\s+(\d+)/
      total_revisions = $1.to_i
      @job.update(total_revisions: total_revisions)
      @repository.update(total_revisions: total_revisions, latest_revision: total_revisions)
      @job.append_output("Total revisions in repository: #{total_revisions}")
    else
      @job.append_output("Warning: Could not parse total revisions from SVN info")
      Rails.logger.warn "SVN info output did not contain revision: #{output}"
    end
  rescue => e
    Rails.logger.warn "Error getting SVN info: #{e.message}"
    @job.append_output("Warning: Error getting SVN info - #{e.message}")
  end
  
  def validate_repository!
    @job.append_output("Validating SVN repository access...")
    @job.update(progress: 10)  # 10% for validation
    
    validator = Repositories::ValidatorService.new(@repository)
    result = validator.call
    
    unless result[:success]
      raise "Repository validation failed: #{result[:errors].join(', ')}"
    end
    
    # Repository에 저장된 total_revisions 사용 (SVN 구조 탐지 시 저장됨)
    if @repository.total_revisions.present? && @repository.total_revisions > 0
      @job.update(total_revisions: @repository.total_revisions)
      @job.append_output("Total revisions in repository: #{@repository.total_revisions} (from previous detection)")
    elsif result[:info] && result[:info][:head_revision]
      # Repository에 없으면 ValidatorService 결과 사용
      total_revisions = result[:info][:head_revision]
      @job.update(total_revisions: total_revisions)
      @repository.update(total_revisions: total_revisions, latest_revision: total_revisions)
      @job.append_output("Total revisions in repository: #{total_revisions}")
    else
      # 둘 다 없으면 SVN info 직접 호출
      get_svn_info
    end
    
    @job.append_output("Repository validated successfully")
  end
  
  def clone_svn_repository
    @job.update_phase!('cloning')
    
    if @repository.migration_method == 'simple'
      @job.append_output("Cloning SVN repository (Simple mode - latest revision only)...")
    else
      @job.append_output("Cloning SVN repository with git-svn (Full history mode)...")
      # Total revision count should already be set from validate_repository!
      if @job.total_revisions.present? && @job.total_revisions > 0
        @job.append_output("Processing #{@job.total_revisions} total revisions...")
      else
        # Fallback: try to get SVN info if not already set
        get_svn_info
      end
    end
    @job.update(progress: 20)
    
    # 체크포인트 저장
    @job.save_checkpoint!(phase: 'cloning')
    
    # Job별 독립 디렉토리 사용
    git_path = get_job_git_directory
    
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
    @job.append_output("SVN URL: #{@repository.svn_url}")
    
    FileUtils.mkdir_p(git_path.to_s)
    
    # 현재 디렉토리 저장
    original_dir = Dir.pwd
    target_dir = git_path.to_s
    
    # 이미 target_dir에 있으면 chdir 불필요
    if File.realpath(original_dir) == File.realpath(target_dir)
      # 이미 올바른 디렉토리에 있음
      # git init first
      system('git', 'init')
      
      # Git 설정 (파일명 문제 방지)
      system('git', 'config', 'core.precomposeunicode', 'false')  # macOS 유니코드 문제
      system('git', 'config', 'core.quotepath', 'false')  # 한글 파일명 처리
      
      # git svn init with options
      cmd = ['git', 'svn', 'init']
      
      # URL 분석을 더 정확하게
      url_has_layout = false
      if @repository.svn_url =~ /\/(trunk|branches|tags)(\/|$)/
        url_has_layout = true
        @job.append_output("URL contains layout path: #{$1}")
      end
      
      # SVN 레이아웃 옵션 (단일 원천 사용)
      layout_options = @repository.git_svn_layout_options
      if url_has_layout && layout_options.any?
        @job.append_output("WARNING: URL contains layout path but layout options provided. This may cause conflicts.")
        @job.append_output("Skipping layout options to avoid conflicts.")
        # 레이아웃 옵션 제거
      elsif layout_options.empty?
        @job.append_output("No layout options needed")
      else
        cmd += layout_options
        @job.append_output("Using layout options: #{layout_options.join(' ')}")
      end
      
      # 메타데이터 포함 (리비전 추적을 위해 필요)
      # --no-metadata를 사용하면 재개 기능이 작동하지 않음
      
      # Authors 파일은 fetch 단계에서 사용 (init에서는 지원하지 않음)
      
      # SVN URL
      cmd << @repository.svn_url
      
      # Execute init
      @job.append_output("Executing: #{cmd.join(' ')}")
      output = `#{cmd.join(' ')} 2>&1`
      unless $?.success?
        @job.append_error("git svn init failed with output: #{output}")
        raise "git svn init failed: #{output}"
      end
      
      @job.append_output("git-svn repository initialized successfully")
      @job.append_output("Init output: #{output}") if output.present?
      
      # 초기화 후 상태 확인
      config_output = `git config --get-regexp svn 2>&1`
      @job.append_output("Git SVN config: #{config_output}") if config_output.present?
      
      # .git/svn 디렉토리 확인
      svn_dir = File.join(git_path.to_s, '.git', 'svn')
      if File.directory?(svn_dir)
        @job.append_output(".git/svn directory created successfully")
      else
        @job.append_error("Warning: .git/svn directory not created")
      end
      
      # git svn info로 연결 테스트
      info_output = `git svn info 2>&1`
      if info_output.include?("Unable to determine")
        @job.append_error("Warning: git svn info shows connection issues: #{info_output.lines.first}")
      else
        @job.append_output("git svn info check passed")
      end
    else
      # 다른 디렉토리에 있으면 chdir 필요
      Dir.chdir(target_dir) do
        # git init first
        system('git', 'init')
        
        # Git 설정 (파일명 문제 방지)
        system('git', 'config', 'core.precomposeunicode', 'false')  # macOS 유니코드 문제
        system('git', 'config', 'core.quotepath', 'false')  # 한글 파일명 처리
        
        # git svn init with options
        cmd = ['git', 'svn', 'init']
        
        # URL 분석을 더 정확하게
        url_has_layout = false
        if @repository.svn_url =~ /\/(trunk|branches|tags)(\/|$)/
          url_has_layout = true
          @job.append_output("URL contains layout path: #{$1}")
        end
        
        # SVN 레이아웃 옵션 (단일 원천 사용)
        layout_options = @repository.git_svn_layout_options
        if url_has_layout && layout_options.any?
          @job.append_output("WARNING: URL contains layout path but layout options provided. This may cause conflicts.")
          @job.append_output("Skipping layout options to avoid conflicts.")
          # 레이아웃 옵션 제거
        elsif layout_options.empty?
          @job.append_output("No layout options needed")
        else
          cmd += layout_options
          @job.append_output("Using layout options: #{layout_options.join(' ')}")
        end
        
        # 메타데이터 포함 (리비전 추적을 위해 필요)
        # --no-metadata를 사용하면 재개 기능이 작동하지 않음
        
        # Authors 파일은 fetch 단계에서 사용 (init에서는 지원하지 않음)
        
        # SVN URL
        cmd << @repository.svn_url
        
        # Execute init
        @job.append_output("Executing: #{cmd.join(' ')}")
        output = `#{cmd.join(' ')} 2>&1`
        unless $?.success?
          @job.append_error("git svn init failed with output: #{output}")
          raise "git svn init failed: #{output}"
        end
        
        @job.append_output("git-svn repository initialized successfully")
        @job.append_output("Init output: #{output}") if output.present?
        
        # 초기화 후 상태 확인
        config_output = `git config --get-regexp svn 2>&1`
        @job.append_output("Git SVN config: #{config_output}") if config_output.present?
        
        # .git/svn 디렉토리 확인
        svn_dir = File.join(target_dir, '.git', 'svn')
        if File.directory?(svn_dir)
          @job.append_output(".git/svn directory created successfully")
        else
          @job.append_error("Warning: .git/svn directory not created")
        end
        
        # git svn info로 연결 테스트
        info_output = `git svn info 2>&1`
        if info_output.include?("Unable to determine")
          @job.append_error("Warning: git svn info shows connection issues: #{info_output.lines.first}")
        else
          @job.append_output("git svn info check passed")
        end
      end
    end
  end
  
  def execute_batch_fetch(git_path, start_revision)
    @job.append_output("Starting batch fetch from revision #{start_revision}...")
    
    # 배치 크기 설정 (한 번에 가져올 리비전 수)
    # 체크포인트에서 재개하는 경우 이전 배치 크기 사용
    if @job.checkpoint_data && @job.checkpoint_data['batch_size']
      batch_size = @job.checkpoint_data['batch_size']
      @job.append_output("Using previous batch size: #{batch_size}")
    else
      batch_size = ENV.fetch('SVN_BATCH_SIZE', '100').to_i
    end
    
    Dir.chdir(git_path.to_s) do
      current_rev = start_revision
      retry_count = {}  # 각 리비전별 재시도 횟수 추적
      exit_status = nil  # 블록 밖에서도 사용할 수 있도록 변수 초기화
      
      while current_rev <= (@job.total_revisions || Float::INFINITY)
        end_rev = [current_rev + batch_size - 1, @job.total_revisions].compact.min
        
        # 재시도 횟수 체크
        retry_key = "#{current_rev}-#{end_rev}"
        retry_count[retry_key] ||= 0
        
        if retry_count[retry_key] > 5
          @job.append_error("Failed to fetch revision range #{retry_key} after 5 retries")
          @job.append_error("Skipping to next range to avoid infinite loop")
          current_rev = end_rev + 1
          next
        end
        
        @job.append_output("Fetching revisions #{current_rev} to #{end_rev}... (attempt #{retry_count[retry_key] + 1})")
        
        # 현재 git-svn 상태 확인
        info_output = `git svn info 2>&1`
        if info_output.include?("Unable to determine upstream SVN information")
          @job.append_error("git-svn is not properly initialized. Attempting to reinitialize...")
          # git svn init이 제대로 안 된 경우
          init_cmd = ['git', 'svn', 'init']
          init_cmd += @repository.git_svn_layout_options
          init_cmd << @repository.svn_url
          
          init_result = `#{init_cmd.join(' ')} 2>&1`
          @job.append_output("Reinitialization result: #{init_result}")
        end
        
        # git svn fetch with revision range
        cmd = if @repository.migration_method == 'simple'
                # Simple mode: 최근 10개 리비전 가져오기 (커밋 생성을 위해)
                if @job.total_revisions && @job.total_revisions > 0
                  # 최근 10개 리비전 범위 계산
                  start_rev = [@job.total_revisions - 9, 1].max
                  end_rev = @job.total_revisions
                  @job.append_output("Simple mode: fetching recent revisions #{start_rev}:#{end_rev} for commit generation")
                  ['git', 'svn', 'fetch', '-r', "#{start_rev}:#{end_rev}"]
                else
                  # 전체 리비전을 가져오기
                  @job.append_output("Simple mode: fetching all revisions (no total revision info)")
                  ['git', 'svn', 'fetch']
                end
              else
                ['git', 'svn', 'fetch', '-r', "#{current_rev}:#{end_rev}"]
              end
        
        # Authors 파일 추가
        authors_file = create_authors_file
        if authors_file && File.exist?(authors_file)
          cmd += ['--authors-file', authors_file]
          @job.append_output("Using authors file with #{@repository.authors_mapping&.size || 0} mappings")
        else
          if @repository.migration_method == 'simple'
            @job.append_output("Simple mode: Proceeding without authors file")
          else
            @job.append_output("Full mode: Proceeding without authors file (will use SVN usernames)")
          end
        end
        
        # 명령어 로깅
        @job.append_output("Executing command: #{cmd.join(' ')}")
        
        success = false
        error_output = []
        
        # 프로세스 시작 전 체크
        memory_info = `free -m 2>/dev/null | grep Mem: | awk '{print "Total: " $2 "MB, Used: " $3 "MB, Free: " $4 "MB"}'`
        @job.append_output("Memory status before fetch: #{memory_info.strip}") if memory_info.present?
        
        # 현재 리비전 범위 상태 확인
        @job.append_output("Fetching revision range: #{current_rev}-#{end_rev}")
        
        # git-svn 상태 체크
        git_svn_url = `git config --get svn-remote.svn.url 2>&1`.strip
        git_svn_fetch = `git config --get svn-remote.svn.fetch 2>&1`.strip
        if git_svn_url.present?
          @job.append_output("git-svn URL config: #{git_svn_url}")
          @job.append_output("git-svn fetch config: #{git_svn_fetch}")
        end
        
        Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
          pid = wait_thr.pid
          @job.append_output("Started git-svn process with PID: #{pid}")
          
          # 패스워드 처리
          if @repository.auth_type == 'basic' && @repository.password.present?
            stdin.puts @repository.password
            stdin.close
          end
          
          # 인스턴스 변수로 변경하여 스레드 간 공유 가능하게 함
          @last_output_time = Time.now
          @output_count = 0
          
          # stdout 처리
          stdout_thread = Thread.new do
            stdout.each_line do |line|
              @job.append_output("git-svn: #{line.strip}")
              # 배치 fetch 중에도 진행률 업데이트
              update_progress_from_git_svn(line)
              @last_output_time = Time.now  # 인스턴스 변수로 업데이트
              @output_count += 1
            end
          rescue => e
            @job.append_error("stdout thread error: #{e.message}")
          end
          
          # stderr 처리
          stderr_thread = Thread.new do
            stderr.each_line do |line|
              error_output << line.strip
              @job.append_output("git-svn stderr: #{line.strip}")
              @last_output_time = Time.now  # stderr 출력도 활동으로 간주
              
              # 중요한 에러 패턴 감지
              if line.include?("Connection reset") || line.include?("Connection closed")
                @job.append_error("SVN connection lost: #{line}")
              elsif line.include?("Out of memory") || line.include?("Cannot allocate")
                @job.append_error("Memory exhausted: #{line}")
              elsif line.include?("signal") || line.include?("Killed")
                @job.append_error("Process killed: #{line}")
              elsif line.include?("Authorization failed")
                @job.append_error("SVN authorization failed: #{line}")
              elsif line.include?("Filesystem has no item")
                @job.append_error("SVN path not found: #{line}")
              elsif line.include?("Malformed XML") || line.include?("Corrupt node-revision")
                @job.append_error("SVN repository corruption detected: #{line}")
              elsif line.include?("Cannot accept non-LF line endings")
                @job.append_error("Line ending problem: #{line}")
              elsif line.include?("Checksum mismatch")
                @job.append_error("SVN checksum error (corrupted data): #{line}")
              end
            end
          rescue => e
            @job.append_error("stderr thread error: #{e.message}")
          end
          
          # 프로세스 모니터링
          @process_died = false  # 인스턴스 변수로 변경
          
          # 타임아웃 설정 (환경변수로 조정 가능)
          # SourceForge 같은 느린 서버를 위해 타임아웃 증가
          warning_timeout = ENV.fetch('GITSVN_OUTPUT_WARNING', '300').to_i  # 기본 5분
          stuck_timeout = ENV.fetch('GITSVN_OUTPUT_TIMEOUT', '1200').to_i    # 기본 20분 (증가)
          
          monitor_thread = Thread.new do
            loop do
              sleep 10  # 10초마다 체크
              
              # 프로세스 생존 확인
              begin
                Process.kill(0, pid)
                
                # 마지막 출력 이후 시간 체크
                time_since_output = Time.now - @last_output_time
                
                if time_since_output > warning_timeout && @output_count > 0
                  @job.append_output("Warning: No output for #{warning_timeout} seconds, process might be stuck")
                  
                  # stuck_timeout 이상 멈춰있으면 프로세스 종료
                  if time_since_output > stuck_timeout
                    @job.append_error("Process appears frozen after #{stuck_timeout} seconds, terminating...")
                    Process.kill("TERM", pid) rescue nil
                    sleep 2
                    Process.kill("KILL", pid) rescue nil
                    @process_died = true
                    break
                  end
                end
              rescue Errno::ESRCH
                @job.append_error("git-svn process (PID #{pid}) died unexpectedly")
                @process_died = true
                break
              end
              
              break unless wait_thr.alive?
            end
          rescue => e
            @job.append_error("Monitor thread error: #{e.message}")
          end
          
          # 스레드 완료 대기
          stdout_thread.join
          stderr_thread.join
          monitor_thread.kill rescue nil
          
          # 프로세스 종료 상태 확인
          exit_status = wait_thr.value
          success = exit_status.success? && !@process_died
          
          # 종료 코드 로깅
          unless success
            exit_code = exit_status.exitstatus
            @job.append_error("git svn fetch exited with code: #{exit_code}")
            
            # Signal 6 (SIGABRT) 처리 - exit code 134
            if exit_code == 134 || exit_status.signaled?
              signal_name = exit_status.signaled? ? (Signal.signame(exit_status.termsig) rescue exit_status.termsig) : 'SIGABRT'
              @job.append_error("Process terminated by signal: #{signal_name}")
              @job.append_error("This is often caused by memory issues or internal git-svn errors")
            end
          end
          
          @job.append_output("git-svn process completed with #{@output_count} output lines")
        end
        
        unless success
          # Lock 파일 정리 (실패 시 반드시 정리)
          lock_files = Dir.glob("#{git_path}/.git/**/*.lock")
          if lock_files.any?
            lock_files.each { |f| File.delete(f) rescue nil }
            @job.append_output("Cleaned up #{lock_files.size} lock files")
          end
          
          # 정확한 범위 로깅
          actual_range = "#{current_rev}-#{end_rev}"
          @job.append_error("Batch fetch failed at revision #{actual_range}")
          
          
          # 에러 메시지 분석
          error_msg = error_output.join("\n")
          
          # git-svn의 Warning 메시지는 무시 (W: 로 시작하는 메시지)
          # empty_dir 관련 경고는 정상적인 git-svn 동작
          if error_msg.lines.all? { |line| 
            line.strip.empty? || 
            line.start_with?("W: ") || 
            line.include?("empty_dir") ||
            line.include?("Checked out HEAD")
          }
            @job.append_output("git-svn warnings (ignored): #{error_msg.lines.first(3).join.strip}...") if error_msg.present?
            error_msg = ""  # 경고만 있으면 에러 메시지 제거
          end
          
          # HTTP truncated response 처리
          if error_msg.include?("truncated HTTP response") || error_msg.include?("ra_serf")
            @job.append_error("Network error: HTTP response was truncated")
            @job.append_error("This often happens with large repositories or unstable connections")
            
            # 실제로 가져온 리비전 확인
            last_fetched = get_last_fetched_revision(git_path)
            
            # 진전이 있으면 계속
            if last_fetched > 0 && last_fetched > current_rev
              @job.append_output("Partial fetch succeeded: got revisions #{current_rev} to #{last_fetched}")
              save_batch_checkpoint(last_fetched)
              current_rev = last_fetched + 1
              
              # 배치 크기 동적 조절
              if batch_size > 10
                # 진전이 있으면 배치 크기를 덜 줄임
                batch_size = [batch_size * 3 / 4, 10].max
                @job.append_output("Adjusting batch size to #{batch_size} for stability")
              else
                # 작은 배치는 유지
                @job.append_output("Keeping small batch size: #{batch_size}")
              end
              
              sleep 1  # 서버 부하 경감
              retry_count[retry_key] += 1  # 재시도 횟수 증가
              next  # 계속 진행
            elsif last_fetched == current_rev - 1
              # 아무것도 못 가져온 경우
              @job.append_error("No progress made in this batch")
              
              if batch_size > 5
                batch_size = 5
                @job.append_output("Reducing batch size to minimum (5) and retrying")
                sleep 2
                retry_count[retry_key] += 1
                next
              else
                # 최소 배치에서도 실패
                @job.append_error("Cannot fetch even with minimum batch size")
                # 하나씩 시도
                batch_size = 1
                @job.append_output("Attempting single revision fetch")
                sleep 3
                retry_count[retry_key] += 1
                next
              end
            end
          end
          
          # Signal 6 / Exit code 134 처리  
          if exit_status && (exit_status.exitstatus == 134 || error_msg.include?("signal 6"))
            @job.append_error("git-svn crashed with SIGABRT (memory/internal error)")
            
            # 메모리 상태 체크
            memory_info = `free -m 2>/dev/null | grep Mem: | awk '{print "Total: " $2 "MB, Used: " $3 "MB, Free: " $4 "MB"}'`
            @job.append_output("Memory status after crash: #{memory_info.strip}") if memory_info.present?
            
            # 배치 크기를 크게 줄이기
            if batch_size > 5
              batch_size = 5
              @job.append_output("Reducing batch size to minimum (5) due to SIGABRT")
              
              # 마지막 성공 지점에서 재시작
              last_fetched = get_last_fetched_revision(git_path)
              if last_fetched > 0
                save_batch_checkpoint(last_fetched)
                current_rev = last_fetched + 1
                
                # git-svn 캐시 정리
                `git gc --aggressive 2>&1`
                @job.append_output("Cleaned git cache before retry")
                
                sleep 2  # 짧은 대기
                retry_count[retry_key] += 1
                next  # 재시도
              end
            end
          end
          
          # 인증 문제인지 확인 (실제 인증 에러만 감지)
          if !error_msg.empty? && (
            error_msg.include?("Authentication") || 
            error_msg.include?("authorization failed") || 
            error_msg.include?("401 Authorization Required") || 
            error_msg.include?("403 Forbidden") ||
            error_msg.include?("Invalid username or password") ||
            error_msg.include?("E170001")  # SVN authorization failed error code
          )
            @job.append_error("Authentication failed. Please check your credentials.")
            @job.update!(status: 'failed', phase: 'cloning')
            raise "Authentication failed: #{error_msg}"
          end
          
          # 네트워크 문제인지 확인
          if error_msg.include?("Could not resolve host") || error_msg.include?("Connection refused") || error_msg.include?("timeout")
            @job.append_error("Network error. Please check the SVN URL and network connectivity.")
            @job.update!(status: 'failed', phase: 'cloning')
            raise "Network error: #{error_msg}"
          end
          
          # 실제로 가져온 마지막 리비전 확인
          last_fetched = get_last_fetched_revision(git_path)
          @job.append_output("Last successfully fetched revision: #{last_fetched}")
          
          # 실패 원인 분석
          if error_msg.include?("path not found")
            @job.append_error("SVN path issue - the repository structure may have changed at revision #{current_rev}")
            @job.append_error("Consider checking the SVN repository history for structural changes")
          elsif error_msg.include?("Filesystem has no item")
            @job.append_error("The requested path doesn't exist in SVN at revision #{current_rev}")
            @job.append_error("This often happens when trunk/branches/tags paths are incorrect")
          elsif error_msg.empty? && last_fetched == 0
            @job.append_error("git-svn process died without error message - likely memory or timeout issue")
          end
          
          # 일부라도 성공했으면 그 지점을 저장하고 계속
          if last_fetched > 0 && last_fetched >= current_rev
            @job.append_output("Partial success: fetched up to revision #{last_fetched}")
            save_batch_checkpoint(last_fetched)
            current_rev = last_fetched + 1  # 다음 리비전부터 계속
            
            # 배치 크기 조정
            if batch_size > 5
              batch_size = [batch_size / 2, 5].max
              @job.append_output("Reducing batch size to #{batch_size} for next attempt")
            end
            retry_count[retry_key] += 1
            next  # 계속 진행
          end
          
          # 배치 크기가 너무 큰 경우 줄여서 재시도
          if batch_size > 5
            @job.append_output("Batch size (#{batch_size}) might be too large. Retrying with smaller batch...")
            batch_size = [batch_size / 2, 5].max
            @job.append_output("Reduced batch size to #{batch_size}")
            
            # 재시도 전 짧은 대기
            sleep 1
            retry_count[retry_key] += 1
            next  # 다시 시도
          else
            # 아무것도 못 가져왔으면 실패
            @job.append_output("No revisions fetched. Error: #{error_msg}")
            @job.update!(status: 'failed', phase: 'cloning')
            raise "Batch fetch failed: #{error_msg}"
          end
        end
        
        # 성공한 경우 실제 가져온 리비전 확인
        last_fetched = get_last_fetched_revision(git_path)
        @job.append_output("Successfully fetched revisions #{current_rev}-#{end_rev}, last commit at r#{last_fetched}")
        
        # 성공 시 배치 크기를 조금씩 늘림 (최대 200까지)
        if batch_size < 200 && retry_count[retry_key] == 0
          new_batch_size = [(batch_size * 1.2).to_i, 200].min
          if new_batch_size > batch_size
            @job.append_output("Increasing batch size from #{batch_size} to #{new_batch_size} after success")
            batch_size = new_batch_size
          end
        end
        
        save_batch_checkpoint(last_fetched, batch_size)
        
        # Simple mode는 한 번만 실행
        if @repository.migration_method == 'simple'
          @job.append_output("Simple mode: Fetched recent revisions successfully")
          break
        end
        
        # 모든 리비전을 가져왔는지 확인
        if @job.total_revisions && last_fetched >= @job.total_revisions
          @job.append_output("All #{@job.total_revisions} revisions fetched successfully!")
          break
        end
        
        # 다음 배치 시작점 설정
        current_rev = end_rev + 1
        
        # 배치 처리 중 진행상황 로깅
        if @job.total_revisions
          remaining = @job.total_revisions - last_fetched
          progress_percent = ((last_fetched.to_f / @job.total_revisions) * 100).round(1)
          @job.append_output("Progress: #{last_fetched}/#{@job.total_revisions} revisions fetched (#{progress_percent}%), #{remaining} remaining")
        end
      end
    rescue => e
      # 배치 처리 중 오류 발생 시 Job 상태 업데이트
      @job.update!(status: 'failed', phase: 'cloning')
      raise e
    end
    
    @job.update(progress: 70)
  end
  
  def save_batch_checkpoint(last_revision, batch_size = nil)
    checkpoint_data = {
      phase: 'cloning',
      last_fetched_revision: last_revision
    }
    checkpoint_data[:batch_size] = batch_size if batch_size
    
    @job.save_checkpoint!(checkpoint_data)
    @job.append_output("Checkpoint saved at revision #{last_revision}")
  end
  
  def build_git_svn_command(target_path)
    cmd = ['git', 'svn', 'clone']
    
    # Simple mode는 init 후 fetch로 처리하므로 여기서는 설정하지 않음
    if @repository.migration_method == 'simple'
      @job.append_output("Using simple mode: will fetch recent 10 revisions for commit generation")
    else
      @job.append_output("Using full mode: fetching entire commit history")
    end
    
    # SVN 레이아웃 옵션 (단일 원천 사용)
    layout_options = @repository.git_svn_layout_options
    if layout_options.empty?
      @job.append_output("SVN URL already contains specific path, skipping layout options")
    else
      cmd += layout_options
      @job.append_output("Using layout options: #{layout_options.join(' ')}")
    end
    
    # Ignore patterns 옵션 추가
    if @repository.ignore_patterns.present?
      ignore_regex = build_ignore_regex(@repository.ignore_patterns)
      if ignore_regex
        cmd += ['--ignore-paths', ignore_regex]
        @job.append_output("Excluding files matching: #{ignore_regex}")
      end
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
    
    # 디렉토리 존재 확인
    unless File.directory?(git_path_str)
      @job.append_error("Git directory does not exist: #{git_path_str}")
      raise "Git directory not found: #{git_path_str}"
    end
    
    # .git/svn 존재 확인
    unless File.exist?("#{git_path_str}/.git/svn")
      @job.append_error("Not a git-svn repository: #{git_path_str}")
      raise "Not a git-svn repository: #{git_path_str}"
    end
    
    # 현재 디렉토리가 이미 git_path인지 확인
    if Dir.pwd == File.expand_path(git_path_str)
      # 이미 올바른 디렉토리에 있으므로 chdir 없이 실행
      execute_git_svn_fetch_internal(git_path_str)
    else
      # 디렉토리 변경이 필요한 경우
      Dir.chdir(git_path_str) do
        execute_git_svn_fetch_internal(git_path_str)
      end
    end
  end
  
  def execute_git_svn_fetch_internal(git_path)
    # 현재 상태 확인 - 이미 올바른 디렉토리에 있으므로 직접 호출
    last_rev = get_last_fetched_revision_internal
    @job.append_output("마지막으로 가져온 리비전: r#{last_rev}")
    
    # 현재 HEAD 리비전 확인
    head_rev = @job.total_revisions || @repository.total_revisions
    if last_rev && head_rev && last_rev >= head_rev
      @job.append_output("모든 리비전이 이미 가져와졌습니다 (#{last_rev}/#{head_rev})")
      return
    end
    
    # git svn fetch 실행
    cmd = ['git', 'svn', 'fetch']
    @job.append_output("Executing: #{cmd.join(' ')}")
    @job.append_output("Current directory: #{Dir.pwd}")
    
    stderr_buffer = []
    stdout_buffer = []
    has_output = false
    
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      # stdout 읽기 스레드
      stdout_thread = Thread.new do
        stdout.each_line do |line|
          has_output = true
          stdout_buffer << line
          @job.append_output("git-svn: #{line.strip}")
          update_progress_from_git_svn(line)
        end
      end
      
      # stderr 읽기 스레드
      stderr_thread = Thread.new do
        stderr.each_line do |line|
          stderr_buffer << line
          # stderr도 중요한 정보를 담을 수 있음
          if line.include?('hint:') || line.include?('Initialized')
            @job.append_output("git-svn: #{line.strip}")
          else
            @job.append_error("git-svn stderr: #{line.strip}")
          end
        end
      end
      
      # 두 스레드가 완료되기를 기다림
      stdout_thread.join
      stderr_thread.join
      
      unless wait_thr.value.success?
        error_output = stderr_buffer.join
        exit_code = wait_thr.value.exitstatus
        
        # 아무 출력이 없었고 exit code만 있는 경우
        if !has_output && error_output.empty?
          @job.append_error("git svn fetch terminated with exit code #{exit_code} without any output")
          @job.append_error("Possible causes: memory limit, timeout, or git-svn configuration issue")
          
          # git svn info로 상태 확인
          info_output = `git svn info 2>&1`
          @job.append_output("git svn info output: #{info_output}")
        else
          @job.append_error("git svn fetch failed with exit code: #{exit_code}")
          @job.append_error("Error output: #{error_output}") if error_output.present?
        end
        
        raise "git svn fetch failed with exit code #{exit_code}"
      end
    end
    
    # 성공했지만 아무것도 가져오지 않은 경우
    if !has_output
      @job.append_output("git svn fetch completed but no new revisions were fetched")
      @job.append_output("Repository might be up to date")
    end
    
    @job.update(progress: 70)
  end
  
  def check_git_svn_integrity(git_path)
    # git-svn의 무결성 체크
    Dir.chdir(git_path.to_s) do
      # git svn info를 실행해서 메타데이터가 정상인지 확인
      output, err, status = Open3.capture3('git', 'svn', 'info')
      
      if status.success?
        @job.append_output("git-svn 메타데이터 정상")
        return true
      else
        if err.include?("Index mismatch") || err.include?("Checksum mismatch")
          @job.append_output("git-svn Index mismatch 감지: #{err.lines.first}")
          return false
        elsif err.include?("Unable to determine upstream SVN information")
          @job.append_output("git-svn 메타데이터 없음")
          return false
        else
          @job.append_output("git-svn 상태 확인 실패: #{err}")
          return false
        end
      end
    end
  rescue => e
    @job.append_output("git-svn integrity check failed: #{e.message}")
    false
  end

  def get_last_fetched_revision(git_path)
    git_path_str = git_path.to_s
    
    # 현재 디렉토리가 이미 git_path인지 확인
    if Dir.pwd == File.expand_path(git_path_str)
      # 이미 올바른 디렉토리에 있으므로 chdir 없이 실행
      get_last_fetched_revision_internal
    else
      # 디렉토리 변경이 필요한 경우
      Dir.chdir(git_path_str) do
        get_last_fetched_revision_internal
      end
    end
  rescue => e
    @job.append_output("Failed to get last revision: #{e.message}")
    @job.checkpoint_data['last_fetched_revision'] || 0
  end
  
  def get_last_fetched_revision_internal
    # git log로 마지막 커밋의 SVN 리비전 확인
    output = `git log -1 --format=%B 2>/dev/null | grep -oP 'git-svn-id:.*@\\K[0-9]+' | head -1`.strip
    
    if output.empty?
      # git svn info로 시도
      svn_info = `git svn info 2>/dev/null`
      if svn_info.include?("Last Changed Rev")
        output = svn_info.match(/Last Changed Rev:\s*(\d+)/)[1] rescue nil
      end
    end
    
    if output.empty?
      # git log에서 모든 git-svn-id 찾기
      all_revisions = `git log --format=%B 2>/dev/null | grep -oP 'git-svn-id:.*@\\K[0-9]+' | sort -n | tail -1`.strip
      output = all_revisions unless all_revisions.empty?
    end
    
    if output.empty?
      # 체크포인트에서 확인
      return @job.checkpoint_data['last_fetched_revision'] || 0
    end
    
    output.to_i
  end
  
  def update_progress_from_git_svn(line)
    # r1234 = abc123... 형식의 출력 파싱
    if line =~ /^r(\d+) = ([a-f0-9]+)/
      revision = $1.to_i
      commit_hash = $2
      
      # 이미 처리한 리비전인지 체크 (중복 방지)
      if @job.current_revision && revision <= @job.current_revision
        return  # 이미 처리한 리뺄전은 무시
      end
      
      # 리비전과 processed_commits 동기화
      @job.update!(
        current_revision: revision,
        processed_commits: revision  # 리비전 번호를 그대로 사용
      )
      
      # 진행률 계산 및 업데이트
      if @job.total_revisions.present? && @job.total_revisions > 0
        # Clone phase is from 20% to 70% (50% of total progress)
        # 단순 비율 계산 (현재 리비전 / 전체 리비전)
        revision_progress = revision.to_f / @job.total_revisions
        
        # 20%에서 시작해서 70%까지 (50% 범위)
        # 정확한 계산: 20 + (revision_progress * 50)
        total_progress = (20 + (revision_progress * 50)).round(1)
        
        # 진행률이 후퇴하지 않도록 보장 (단조 증가)
        current_progress = @job.progress || 20
        
        # 0.5% 이상 변경된 경우만 업데이트 (빈번한 업데이트 방지)
        if total_progress > current_progress && (total_progress - current_progress) >= 0.5
          new_progress = [total_progress, 70].min  # 최대 70%
          @job.update(progress: new_progress.to_i)
        end
        
        # 처리 속도 계산 (매 10개 리비전마다)
        if revision % 10 == 0 && @job.started_at.present?
          elapsed_seconds = Time.zone.now - @job.started_at
          if elapsed_seconds > 0
            speed = revision.to_f / elapsed_seconds
            @job.update(processing_speed: speed.round(2))
            
            # ETA 계산
            if speed > 0
              remaining_revisions = @job.total_revisions - revision
              eta_seconds = remaining_revisions / speed
              @job.update(
                estimated_completion_at: Time.zone.now + eta_seconds.seconds,
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
      # git-svn 클론 후 로컬 브랜치 생성이 필요함
      @job.append_output("Setting up local branches...")
      
      # 현재 브랜치 확인
      current_branch = `git branch --show-current`.strip
      
      if current_branch.empty?
        # git-svn은 detached HEAD 상태로 남아있을 수 있음
        # trunk를 master 브랜치로 체크아웃
        if system('git', 'show-ref', '--verify', '--quiet', 'refs/remotes/svn/trunk')
          system('git', 'checkout', '-b', 'master', 'refs/remotes/svn/trunk')
          @job.append_output("Created master branch from svn/trunk")
        elsif system('git', 'show-ref', '--verify', '--quiet', 'refs/remotes/git-svn')
          system('git', 'checkout', '-b', 'master', 'refs/remotes/git-svn')
          @job.append_output("Created master branch from git-svn")
        elsif system('git', 'rev-parse', '--verify', 'HEAD')
          # HEAD가 있으면 그것으로 master 생성
          system('git', 'checkout', '-b', 'master')
          @job.append_output("Created master branch from HEAD")
        else
          @job.append_error("Warning: No valid ref found to create master branch")
        end
      end
      
      # 지정된 target branch로 이름 변경
      target_branch = @repository.gitlab_target_branch.presence || 'main'
      current_branch = `git branch --show-current`.strip
      
      if current_branch == 'master' && target_branch != 'master'
        system('git', 'branch', '-m', 'master', target_branch)
        @job.append_output("Renamed master to #{target_branch}")
      elsif current_branch != target_branch
        system('git', 'branch', '-m', current_branch, target_branch)
        @job.append_output("Renamed #{current_branch} to #{target_branch}")
      end
      
      # .gitignore 추가 (필요한 경우)
      apply_ignore_patterns(git_path)
    end
    
    @job.append_output("Migration strategy applied")
  end
  
  def apply_ignore_patterns(git_path)
    # .gitignore 생성은 사용자가 선택한 경우에만
    return unless @repository.generate_gitignore && @repository.ignore_patterns.present?
    
    @job.append_output("Creating .gitignore file...")
    
    gitignore_path = File.join(git_path, '.gitignore')
    File.open(gitignore_path, 'w') do |f|
      f.puts "# Generated from migration configuration"
      f.puts "# Files matching these patterns were already excluded from history"
      f.puts @repository.ignore_patterns
    end
    
    # Commit .gitignore
    Dir.chdir(git_path) do
      system('git', 'add', '.gitignore')
      _, _, status = Open3.capture3('git', 'diff', '--cached', '--quiet')
      unless status.success?
        system('git', 'commit', '-m', 'Add .gitignore from migration configuration')
        @job.append_output(".gitignore file committed")
      end
    end
  end
  
  def build_ignore_regex(patterns)
    return nil if patterns.blank?
    
    # .gitignore 패턴을 regex로 변환
    regex_parts = []
    
    patterns.lines.each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')
      
      # .gitignore 패턴을 Perl regex로 변환
      regex = line.dup
      
      # 특수 문자 이스케이프
      regex.gsub!('.', '\.')
      regex.gsub!('+', '\+')
      regex.gsub!('(', '\(')
      regex.gsub!(')', '\)')
      regex.gsub!('[', '\[')
      regex.gsub!(']', '\]')
      regex.gsub!('{', '\{')
      regex.gsub!('}', '\}')
      
      # * -> [^/]*  (디렉토리 구분자 제외한 모든 문자)
      # ** -> .*    (모든 경로)
      regex.gsub!('**', '§DOUBLE§')  # 임시 마커
      regex.gsub!('*', '[^/]*')
      regex.gsub!('§DOUBLE§', '.*')
      
      # 디렉토리인 경우 /로 끝남
      if line.end_with?('/')
        regex = "#{regex}.*"
      elsif !line.include?('/')
        # 파일명만 있는 경우 모든 경로에서 매칭
        regex = "(^|.*/)" + regex + "($|/.*)"
      else
        # 경로가 포함된 경우
        regex = "^#{regex}($|/.*)"
      end
      
      regex_parts << regex
    end
    
    return nil if regex_parts.empty?
    
    # 모든 패턴을 OR로 연결
    "^(#{regex_parts.join('|')})$"
  rescue => e
    @job.append_output("Warning: Failed to build ignore regex: #{e.message}")
    nil
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
      
      # 현재 브랜치 확인
      current_branch = `git branch --show-current`.strip
      @job.append_output("Current branch: #{current_branch}")
      
      # 브랜치가 없으면 에러
      if current_branch.empty?
        @job.append_error("No local branch found. Cannot push to GitLab.")
        raise "No local branch to push"
      end
      
      # Target branch 확인 (Repository에 설정된 값 사용)
      target_branch = @repository.gitlab_target_branch.presence || 'main'
      @job.append_output("Pushing to GitLab branch: #{target_branch}")
      
      # 현재 브랜치를 GitLab의 target branch로 푸시
      Open3.popen3('git', 'push', '-u', push_url, "#{current_branch}:#{target_branch}") do |stdin, stdout, stderr, wait_thr|
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
            success = system('git', 'push', '-u', '--force', push_url, "#{current_branch}:#{target_branch}")
            unless success
              @job.append_error("Failed to push to GitLab even with force push")
              raise "Push to GitLab failed"
            end
          end
        end
      end
      
      # 다른 브랜치들도 푸시 (있다면)
      other_branches = `git branch -r | grep -E 'svn/(branches|tags)' | sed 's/.*svn\\///'`.split("\n")
      if other_branches.any?
        @job.append_output("Pushing additional branches: #{other_branches.join(', ')}")
        other_branches.each do |branch|
          branch_name = branch.strip.gsub(/^(branches|tags)\//, '')
          # 로컬 브랜치 생성 후 푸시
          system('git', 'checkout', '-b', branch_name, "refs/remotes/svn/#{branch}")
          system('git', 'push', push_url, "#{branch_name}:#{branch_name}")
        end
        # 원래 브랜치로 돌아가기
        system('git', 'checkout', current_branch)
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
    # Create authors file in shared location for repository
    temp_dir = Rails.root.join('tmp', 'authors')
    FileUtils.mkdir_p(temp_dir)
    
    authors_file_path = temp_dir.join("repository_#{@repository.id}_authors.txt")
    
    # 이미 파일이 있으면 재사용 (재개/retry 시)
    if File.exist?(authors_file_path)
      @job.append_output("Using existing authors file: #{authors_file_path}")
      line_count = File.readlines(authors_file_path).size
      @job.append_output("Authors file contains #{line_count} mappings")
      return authors_file_path.to_s
    end
    
    # Full mode에서는 실제 SVN에서 모든 authors 추출
    if @repository.migration_method == 'git-svn'
      @job.append_output("Full mode: Extracting all authors from SVN repository...")
      extractor = Repositories::AuthorsExtractor.new(@repository)
      
      begin
        svn_authors = extractor.extract_all_authors
        @job.append_output("Found #{svn_authors.size} unique authors in SVN history")
        
        # Repository에 저장된 매핑과 병합
        existing_mappings = {}
        if @repository.authors_mapping.present?
          # authors_mapping이 String이면 Array로 변환
          if @repository.authors_mapping.is_a?(String)
            # String 형태의 authors_mapping 파싱
            @repository.authors_mapping.split("\n").each do |line|
              next if line.blank?
              if line =~ /^(\S+)\s*=\s*(.+?)\s*<(.+?)>$/
                svn_name = $1
                git_name = $2.strip
                git_email = $3.strip
                existing_mappings[svn_name] = {
                  'svn_name' => svn_name,
                  'git_name' => git_name,
                  'git_email' => git_email
                }
              end
            end
          elsif @repository.authors_mapping.is_a?(Array)
            @repository.authors_mapping.each do |mapping|
              existing_mappings[mapping['svn_name']] = mapping
            end
          end
          @job.append_output("Using #{existing_mappings.size} pre-configured author mappings")
        end
        
        # 파일 생성
        File.open(authors_file_path, 'w') do |file|
          svn_authors.each do |svn_name|
            if existing_mappings[svn_name]
              # 사용자가 설정한 매핑 사용
              mapping = existing_mappings[svn_name]
              file.puts "#{svn_name} = #{mapping['git_name']} <#{mapping['git_email']}>"
            else
              # 기본 매핑 생성
              file.puts "#{svn_name} = #{svn_name} <#{svn_name.gsub(/[^a-zA-Z0-9]/, '')}@example.com>"
              @job.append_output("Auto-generated mapping for: #{svn_name}")
            end
          end
        end
        
        @job.append_output("Created authors file with #{svn_authors.size} total mappings")
        return authors_file_path.to_s
        
      rescue => e
        @job.append_output("ERROR: Could not extract authors: #{e.message}")
        @job.append_output("Full mode requires complete authors list. Migration may fail.")
        # Full mode에서는 authors 파일이 필수
        return nil
      end
    end
    
    # Simple mode: Repository의 authors_mapping만 사용
    return nil unless @repository.authors_mapping.present?
    
    # Handle different formats of authors_mapping
    authors_data = if @repository.authors_mapping.is_a?(String)
                     # If it's a string (from textarea), parse it line by line
                     lines = @repository.authors_mapping.split("\n").reject(&:blank?)
                     return nil if lines.empty?
                     lines
                   elsif @repository.authors_mapping.is_a?(Array)
                     # If it's an array of hashes
                     return nil if @repository.authors_mapping.empty?
                     @repository.authors_mapping.map do |author|
                       "#{author['svn_name']} = #{author['git_name']} <#{author['git_email']}>"
                     end
                   else
                     return nil
                   end
    
    # Create authors file in shared location for repository
    # Use repository-specific path so IncrementalSyncJob can also use it
    temp_dir = Rails.root.join('tmp', 'authors')
    FileUtils.mkdir_p(temp_dir)
    
    authors_file_path = temp_dir.join("repository_#{@repository.id}_authors.txt")
    
    File.open(authors_file_path, 'w') do |file|
      authors_data.each do |line|
        file.puts line
      end
    end
    
    @job.append_output("Created authors file with #{authors_data.size} mappings")
    authors_file_path.to_s
  end
  
  # 재개 메서드들
  def resume_cloning
    @job.append_output("Clone 단계에서 재개합니다...")
    
    # Resume 시에는 체크포인트에 저장된 경로 사용
    git_path = @job.checkpoint_data['git_path'] || get_job_git_directory
    
    # 디렉토리가 존재하고 git-svn 메타데이터가 있는 경우
    if git_path && File.exist?(git_path) && File.exist?("#{git_path}/.git/svn")
      # Lock 파일 정리 (resume 시 반드시 정리)
      clean_lock_files(git_path)
      
      # Index mismatch 에러 체크
      if check_git_svn_integrity(git_path)
        # 마지막 성공한 리비전 확인
        last_fetched = get_last_fetched_revision(git_path)
        @job.append_output("마지막으로 성공한 리비전: r#{last_fetched}")
        
        # 체크포인트의 last_fetched_revision 업데이트
        @job.save_checkpoint!(
          phase: 'cloning',
          last_fetched_revision: last_fetched
        )
        
        # 배치 fetch로 이어서 진행 (처음과 동일한 방식)
        execute_batch_fetch(git_path, last_fetched + 1)
      else
        @job.append_output("git-svn 메타데이터가 손상되었습니다. 재구축합니다...")
        
        # 손상된 .git/svn 디렉토리만 삭제
        svn_meta_path = "#{git_path}/.git/svn"
        FileUtils.rm_rf(svn_meta_path) if File.exist?(svn_meta_path)
        
        # git svn init으로 다시 초기화
        execute_git_svn_init(git_path)
        
        # 마지막 성공한 체크포인트부터 재개
        last_checkpoint_rev = @job.checkpoint_data['last_fetched_revision'] || 0
        if last_checkpoint_rev > 0
          @job.append_output("체크포인트 r#{last_checkpoint_rev}부터 재개합니다.")
          execute_batch_fetch(git_path, last_checkpoint_rev + 1)
        else
          @job.append_output("처음부터 다시 fetch합니다.")
          execute_batch_fetch(git_path, 1)
        end
      end
      
      # 다음 단계로
      apply_migration_strategy(git_path)
      gitlab_url = push_to_gitlab(git_path)
      
      @job.mark_as_completed!(gitlab_url)
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
    
    # 체크포인트에서 경로 가져오기
    git_path = @job.checkpoint_data['git_path'] || @repository.local_git_path
    
    # 전략 적용 계속
    apply_migration_strategy(git_path)
    
    # 다음 단계
    push_to_gitlab(git_path)
    
    @job.mark_as_completed!(@repository.gitlab_project_url)
    @job.update_phase!('completed')
  end
  
  def resume_pushing
    @job.append_output("Push 단계에서 재개합니다...")
    
    # 체크포인트에서 경로 가져오기
    git_path = @job.checkpoint_data['git_path'] || @repository.local_git_path
    
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
  
  # Job별 고유 디렉토리 생성/반환
  def get_job_git_directory
    # Job별 디렉토리 경로 (바로 여기에 clone)
    git_path = Rails.root.join('git_repos', "repository_#{@repository.id}", "job_#{@job.id}")
    FileUtils.mkdir_p(git_path)
    
    # 체크포인트에 경로 저장
    @job.update!(checkpoint_data: @job.checkpoint_data.merge('git_path' => git_path.to_s))
    
    # Repository의 local_git_path도 업데이트 (호환성 유지)
    @repository.update!(local_git_path: git_path.to_s)
    
    @job.append_output("Job 디렉토리 생성: #{git_path}")
    
    git_path
  end
  
  # ActionCable로 진행 상태 브로드캐스트
  def broadcast_progress(data)
    JobProgressChannel.broadcast_to(@job, data)
  end
  
  # Lock 파일 정리
  def clean_lock_files(git_path)
    lock_files = Dir.glob("#{git_path}/.git/**/*.lock")
    if lock_files.any?
      lock_files.each { |f| File.delete(f) rescue nil }
      @job.append_output("Cleaned up #{lock_files.size} lock files from previous run")
    end
  end
  
end