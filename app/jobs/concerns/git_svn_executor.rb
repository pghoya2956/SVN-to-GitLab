# frozen_string_literal: true

# Git-SVN 명령 실행을 위한 개선된 모듈
module GitSvnExecutor
  extend ActiveSupport::Concern
  
  # 설정 가능한 타임아웃 값들
  GITSVN_OUTPUT_WARNING = ENV.fetch('GITSVN_OUTPUT_WARNING', '300').to_i  # 5분: 경고
  GITSVN_OUTPUT_TIMEOUT = ENV.fetch('GITSVN_OUTPUT_TIMEOUT', '600').to_i  # 10분: 타임아웃
  GITSVN_KILL_TIMEOUT = ENV.fetch('GITSVN_KILL_TIMEOUT', '1800').to_i    # 30분: 강제 종료
  
  # 재시도 가능한 에러 패턴
  NETWORK_ERROR_PATTERNS = [
    /Connection reset/i,
    /Connection closed/i,
    /truncated HTTP response/i,
    /ra_serf.*connection/i,
    /Network is unreachable/i,
    /503 Service Unavailable/i
  ].freeze
  
  # 치명적 에러 패턴
  FATAL_ERROR_PATTERNS = [
    /Authorization failed/i,
    /403 Forbidden/i,
    /401 Unauthorized/i,
    /Repository.*not found/i,
    /Malformed repository/i
  ].freeze
  
  private
  
  # 개선된 git svn fetch 실행
  def execute_git_svn_fetch_improved(git_path, start_rev, end_rev)
    cmd = build_fetch_command(start_rev, end_rev)
    
    result = {
      success: false,
      output: [],
      errors: [],
      last_revision: nil,
      exit_code: nil,
      should_retry: false
    }
    
    Dir.chdir(git_path) do
      # 실행 전 상태 체크
      unless check_git_svn_health
        @job.append_error("git-svn is not healthy, attempting repair...")
        repair_git_svn_state
      end
      
      # 메모리 체크
      if (min_batch_size = check_memory_constraints)
        @job.append_output("Memory constrained, using batch size: #{min_batch_size}")
        return result.merge(should_retry: true, suggested_batch_size: min_batch_size)
      end
      
      # 명령 실행
      execute_with_monitoring(cmd, result)
    end
    
    result
  end
  
  # git-svn 상태 체크
  def check_git_svn_health
    # .git/svn 디렉토리 존재 확인
    return false unless File.directory?('.git/svn')
    
    # config 확인
    svn_url = `git config --get svn-remote.svn.url 2>&1`.strip
    return false if svn_url.empty?
    
    # index 무결성 확인
    system('git', 'fsck', '--no-dangling', out: File::NULL, err: File::NULL)
  end
  
  # git-svn 상태 복구
  def repair_git_svn_state
    @job.append_output("Attempting to repair git-svn state...")
    
    # 1. 오래된 lock 파일만 정리
    clean_stale_lock_files
    
    # 2. git 인덱스 재구성
    system('git', 'update-index', '--refresh', out: File::NULL, err: File::NULL)
    
    # 3. git-svn 캐시 정리
    system('git', 'gc', '--auto', out: File::NULL, err: File::NULL)
    
    # 4. 필요시 refs 재구성
    if File.exist?('.git/svn/refs')
      @job.append_output("Rebuilding git-svn refs...")
      system('git', 'svn', 'fetch', '--no-follow-parent', out: File::NULL, err: File::NULL)
    end
  end
  
  # 오래된 lock 파일만 안전하게 정리
  def clean_stale_lock_files
    lock_files = Dir.glob('.git/**/*.lock')
    
    lock_files.each do |lock_file|
      begin
        # 10분 이상 된 lock 파일만 처리
        next unless File.mtime(lock_file) < 10.minutes.ago
        
        # lock을 잡고 있는 프로세스 확인
        lock_owner = check_lock_owner(lock_file)
        if lock_owner.nil?
          File.delete(lock_file)
          @job.append_output("Removed stale lock: #{File.basename(lock_file)}")
        else
          @job.append_output("Lock #{File.basename(lock_file)} is held by PID #{lock_owner}")
        end
      rescue => e
        @job.append_error("Error checking lock file: #{e.message}")
      end
    end
  end
  
  # Lock 파일 소유자 확인
  def check_lock_owner(lock_file)
    # git 또는 git-svn 프로세스 찾기
    ps_output = `ps aux | grep -E "(git|git-svn)" | grep -v grep`
    
    ps_output.lines.each do |line|
      parts = line.split
      pid = parts[1].to_i
      
      # 프로세스가 이 디렉토리에서 실행 중인지 확인
      begin
        cwd = File.readlink("/proc/#{pid}/cwd") rescue nil
        return pid if cwd && cwd.include?(Dir.pwd)
      rescue
        # macOS나 /proc이 없는 시스템에서는 건너뜀
        next
      end
    end
    
    nil
  end
  
  # 메모리 제약 체크
  def check_memory_constraints
    # Linux에서만 동작
    return nil unless File.exist?('/proc/meminfo')
    
    meminfo = File.read('/proc/meminfo')
    available_kb = meminfo.match(/MemAvailable:\s+(\d+)/)&.captures&.first&.to_i || 0
    available_mb = available_kb / 1024
    
    if available_mb < 200
      @job.append_error("Critical memory: #{available_mb}MB available")
      return 1  # 한 번에 1개씩만
    elsif available_mb < 500
      @job.append_output("Low memory: #{available_mb}MB available")
      return 5  # 작은 배치
    end
    
    nil  # 메모리 충분
  end
  
  # 명령 실행 및 모니터링
  def execute_with_monitoring(cmd, result)
    @job.append_output("Executing: #{cmd.join(' ')}")
    
    start_time = Time.now
    last_output_time = Time.now
    output_lines = []
    error_lines = []
    process_info = {}
    
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      stdin.close  # git-svn은 stdin을 사용하지 않음
      
      pid = wait_thr.pid
      @job.append_output("Started git-svn process with PID: #{pid}")
      process_info[:pid] = pid
      
      # 출력 처리 스레드
      threads = []
      
      threads << Thread.new do
        stdout.each_line do |line|
          output_lines << line.strip
          @job.append_output("git-svn: #{line.strip}")
          last_output_time = Time.now
          
          # 진행률 업데이트
          update_progress_from_output(line)
        end
      rescue => e
        @job.append_error("stdout thread error: #{e.message}")
      end
      
      threads << Thread.new do
        stderr.each_line do |line|
          error_lines << line.strip
          analyze_error_line(line, result)
          last_output_time = Time.now
        end
      rescue => e
        @job.append_error("stderr thread error: #{e.message}")
      end
      
      # 프로세스 모니터링 (개선된 버전)
      monitor_thread = Thread.new do
        monitor_process(pid, start_time, last_output_time, wait_thr)
      end
      
      # 스레드 종료 대기
      threads.each(&:join)
      monitor_thread.kill rescue nil
      
      # 결과 수집
      exit_status = wait_thr.value
      result[:exit_code] = exit_status.exitstatus
      result[:success] = exit_status.success?
      result[:output] = output_lines
      result[:errors] = error_lines
      
      # 종료 상태 분석
      analyze_exit_status(exit_status, result)
    end
    
    # 마지막 리비전 확인
    result[:last_revision] = get_last_fetched_revision_safe
    
    @job.append_output("Process completed in #{(Time.now - start_time).round(1)} seconds")
  end
  
  # 프로세스 모니터링 (개선)
  def monitor_process(pid, start_time, last_output_time, wait_thr)
    loop do
      sleep 30  # 30초마다 체크
      
      break unless wait_thr.alive?
      
      elapsed = Time.now - start_time
      silence_duration = Time.now - last_output_time.value
      
      # CPU 사용률 체크
      cpu_usage = get_process_cpu_usage(pid)
      
      if silence_duration > GITSVN_OUTPUT_WARNING
        @job.append_output("Warning: No output for #{silence_duration.round}s (CPU: #{cpu_usage}%)")
        
        if cpu_usage < 1.0 && silence_duration > GITSVN_OUTPUT_TIMEOUT
          @job.append_error("Process appears stuck (low CPU), considering termination...")
          
          if silence_duration > GITSVN_KILL_TIMEOUT
            @job.append_error("Terminating stuck process after #{GITSVN_KILL_TIMEOUT}s")
            Process.kill("TERM", pid) rescue nil
            sleep 5
            Process.kill("KILL", pid) rescue nil if wait_thr.alive?
            break
          end
        elsif cpu_usage > 50
          @job.append_output("Process is actively working (high CPU), continuing...")
        end
      end
      
      # 전체 실행 시간 체크
      if elapsed > 7200  # 2시간
        @job.append_error("Process exceeded 2 hour limit, terminating...")
        Process.kill("TERM", pid) rescue nil
        break
      end
    end
  rescue => e
    @job.append_error("Monitor error: #{e.message}")
  end
  
  # 프로세스 CPU 사용률 확인
  def get_process_cpu_usage(pid)
    # Linux
    if File.exist?("/proc/#{pid}/stat")
      stat = File.read("/proc/#{pid}/stat").split
      utime = stat[13].to_i
      stime = stat[14].to_i
      total_time = utime + stime
      
      # 대략적인 CPU 사용률 계산
      return (total_time / 100.0).round(1)
    end
    
    # macOS/기타
    cpu_str = `ps -p #{pid} -o %cpu= 2>/dev/null`.strip
    cpu_str.to_f
  rescue
    0.0
  end
  
  # 에러 라인 분석
  def analyze_error_line(line, result)
    @job.append_output("git-svn stderr: #{line.strip}")
    
    NETWORK_ERROR_PATTERNS.each do |pattern|
      if line =~ pattern
        @job.append_error("Network error detected: #{line.strip}")
        result[:should_retry] = true
        return
      end
    end
    
    FATAL_ERROR_PATTERNS.each do |pattern|
      if line =~ pattern
        @job.append_error("Fatal error: #{line.strip}")
        result[:should_retry] = false
        return
      end
    end
  end
  
  # 종료 상태 분석
  def analyze_exit_status(exit_status, result)
    if exit_status.signaled?
      signal = Signal.signame(exit_status.termsig) rescue exit_status.termsig
      @job.append_error("Process terminated by signal: #{signal}")
      
      case exit_status.termsig
      when 6  # SIGABRT
        @job.append_error("SIGABRT usually indicates assertion failure or abort() call")
        result[:should_retry] = true
        result[:suggested_batch_size] = 5
      when 9  # SIGKILL
        @job.append_error("Process was forcefully killed (possibly OOM)")
        result[:should_retry] = true
        result[:suggested_batch_size] = 1
      when 15  # SIGTERM
        @job.append_error("Process was terminated (timeout or manual)")
        result[:should_retry] = true
      end
    elsif exit_status.exitstatus == 128
      @job.append_error("Git error (exit code 128) - check repository state")
      result[:should_retry] = false
    end
  end
  
  # 안전한 마지막 리비전 확인
  def get_last_fetched_revision_safe
    # Ruby로 파싱 (플랫폼 독립적)
    log_output = `git log -1 --format=%B 2>/dev/null`
    
    if log_output =~ /git-svn-id:.*@(\d+)/
      return $1.to_i
    end
    
    # 대체 방법
    svn_info = `git svn info 2>/dev/null`
    if svn_info =~ /Last Changed Rev:\s*(\d+)/
      return $1.to_i
    end
    
    0
  rescue => e
    @job.append_error("Error getting last revision: #{e.message}")
    0
  end
  
  # fetch 명령 구성
  def build_fetch_command(start_rev, end_rev)
    cmd = ['git', 'svn', 'fetch']
    
    # 리비전 범위
    cmd += ['-r', "#{start_rev}:#{end_rev}"]
    
    # Authors 파일
    if @authors_file_path && File.exist?(@authors_file_path)
      cmd += ['--authors-file', @authors_file_path]
    end
    
    # 로그 창 크기 제한 (메모리 절약)
    cmd += ['--log-window-size=100']
    
    cmd
  end
  
  # 진행률 업데이트
  def update_progress_from_output(line)
    # r1234 = abc123... 형식
    if line =~ /^r(\d+) = ([a-f0-9]+)/
      revision = $1.to_i
      
      # 중복 체크
      return if @job.current_revision && revision <= @job.current_revision
      
      @job.update!(current_revision: revision)
      
      # 진행률 계산
      if @job.total_revisions && @job.total_revisions > 0
        progress = (revision.to_f / @job.total_revisions * 70).round + 10
        @job.update!(progress: progress)
      end
      
      # 주기적 체크포인트
      if revision % 20 == 0
        save_lightweight_checkpoint(revision)
      end
    end
  end
  
  # 경량 체크포인트 저장
  def save_lightweight_checkpoint(revision)
    @job.checkpoint_data ||= {}
    @job.checkpoint_data['last_fetched_revision'] = revision
    @job.checkpoint_data['timestamp'] = Time.current
    @job.save!
  end
end