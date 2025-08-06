module ProgressTrackable
  extend ActiveSupport::Concern
  
  included do
    attr_accessor :start_time, :processed_count
  end
  
  def track_progress
    @start_time ||= Time.current
    @processed_count ||= 0
    
    Thread.new do
      loop do
        break unless job_running?
        
        progress_data = calculate_progress
        broadcast_progress(progress_data)
        
        # 체크포인트 저장 (5분마다)
        save_checkpoint_if_needed
        
        # 실제 진행 상황 체크 (10회 연속 같은 리비전이면 멈춤으로 간주)
        check_actual_progress(progress_data[:current_revision])
        
        sleep 5
      end
    rescue => e
      Rails.logger.error "Progress tracking error: #{e.message}"
    end
  end
  
  def track_progress_with_checkpoint
    track_progress
  end
  
  private
  
  def calculate_progress
    current_revision = get_current_revision
    total_revisions = @repository.svn_structure&.dig('stats', 'latest_revision') || @job.total_revisions || 1000
    
    progress_percentage = [(current_revision.to_f / total_revisions * 100).round(2), 100].min
    elapsed_time = Time.current - @start_time
    
    # 처리 속도 계산 (리비전/초)
    processing_speed = elapsed_time > 0 ? (current_revision.to_f / elapsed_time) : 0
    remaining_revisions = [total_revisions - current_revision, 0].max
    eta_seconds = processing_speed > 0 ? (remaining_revisions / processing_speed) : nil
    
    {
      current_revision: current_revision,
      total_revisions: total_revisions,
      progress_percentage: progress_percentage,
      elapsed_time: format_duration(elapsed_time),
      eta: eta_seconds ? format_duration(eta_seconds) : "계산 중...",
      processing_speed: processing_speed.round(2),
      status: @job.status,
      current_commit_message: get_current_commit_message
    }
  end
  
  def broadcast_progress(data)
    JobProgressChannel.broadcast_to(@job, data)
    
    # eta_seconds 처리 - 이미 숫자인 경우 그대로 사용
    eta_value = data[:eta]
    eta_seconds_value = case eta_value
    when nil, "계산 중..."
      nil
    when Integer, Float
      eta_value.to_i
    when String
      parse_duration_to_seconds(eta_value)
    else
      nil
    end
    
    # Job 모델 업데이트
    @job.update!(
      progress: data[:progress_percentage].to_i,
      current_revision: data[:current_revision],
      total_revisions: data[:total_revisions],
      processing_speed: data[:processing_speed],
      eta_seconds: eta_seconds_value
    )
  end
  
  def get_current_revision
    return 0 unless @repository.local_git_path && File.directory?(@repository.local_git_path)
    
    # 이미 올바른 디렉토리에 있는지 확인
    if Dir.pwd == File.expand_path(@repository.local_git_path)
      # 이미 올바른 디렉토리에 있으므로 chdir 불필요
      output = `git log -1 --grep='^git-svn-id:' --pretty=format:'%b' 2>/dev/null`
      if match = output.match(/git-svn-id:.*@(\d+)/)
        return match[1].to_i
      else
        # git-svn-id가 없으면 커밋 수로 대체
        return `git rev-list --count HEAD 2>/dev/null`.to_i
      end
    else
      # 다른 디렉토리에 있으므로 chdir 필요
      Dir.chdir(@repository.local_git_path) do
        # 최신 커밋의 SVN 리비전 번호 추출
        output = `git log -1 --grep='^git-svn-id:' --pretty=format:'%b' 2>/dev/null`
        if match = output.match(/git-svn-id:.*@(\d+)/)
          match[1].to_i
        else
          # git-svn-id가 없으면 커밋 수로 대체
          `git rev-list --count HEAD 2>/dev/null`.to_i
        end
      end
    end
  rescue => e
    Rails.logger.error "Error getting current revision: #{e.message}"
    0
  end
  
  def get_current_commit_message
    return nil unless @repository.local_git_path && File.directory?(@repository.local_git_path)
    
    # 이미 올바른 디렉토리에 있는지 확인
    if Dir.pwd == File.expand_path(@repository.local_git_path)
      # 이미 올바른 디렉토리에 있으므로 chdir 불필요
      `git log -1 --pretty=format:'%s' 2>/dev/null`.strip
    else
      # 다른 디렉토리에 있으므로 chdir 필요
      Dir.chdir(@repository.local_git_path) do
        `git log -1 --pretty=format:'%s' 2>/dev/null`.strip
      end
    end
  rescue => e
    Rails.logger.error "Error getting commit message: #{e.message}"
    nil
  end
  
  def format_duration(seconds)
    return "계산 중..." if seconds.nil? || seconds.infinite? || seconds.nan?
    
    hours = (seconds / 3600).to_i
    minutes = ((seconds % 3600) / 60).to_i
    secs = (seconds % 60).to_i
    
    if hours > 0
      "#{hours}시간 #{minutes}분"
    elsif minutes > 0
      "#{minutes}분 #{secs}초"
    else
      "#{secs}초"
    end
  end
  
  def parse_duration_to_seconds(duration_str)
    return nil if duration_str.nil? || duration_str == "계산 중..."
    
    total_seconds = 0
    
    # duration_str이 숫자인 경우 그대로 반환
    return duration_str.to_i if duration_str.is_a?(Numeric) || duration_str.to_s =~ /^\d+$/
    
    # 문자열 형식 파싱
    if match = duration_str.to_s.match(/(\d+)시간/)
      total_seconds += match[1].to_i * 3600
    end
    
    if match = duration_str.to_s.match(/(\d+)분/)
      total_seconds += match[1].to_i * 60
    end
    
    if match = duration_str.to_s.match(/(\d+)초/)
      total_seconds += match[1].to_i
    end
    
    total_seconds
  end
  
  def job_running?
    @job.reload.status == 'running'
  end
  
  def save_checkpoint_if_needed
    @last_checkpoint_time ||= Time.current
    
    # 5분마다 또는 중요한 시점에 체크포인트 저장
    if Time.current - @last_checkpoint_time > 5.minutes
      @job.save_checkpoint!(
        current_revision: get_current_revision,
        elapsed_time: Time.current - @start_time,
        progress_percentage: @job.progress
      )
      @last_checkpoint_time = Time.current
      Rails.logger.info "Checkpoint saved for job #{@job.id}"
    end
  end
  
  def check_actual_progress(current_revision)
    @last_revision_check ||= current_revision
    @same_revision_count ||= 0
    
    if @last_revision_check == current_revision
      @same_revision_count += 1
      
      # 10회 연속(50초) 같은 리비전이면 실제로 멈춘 것으로 간주
      if @same_revision_count >= 10
        Rails.logger.warn "Job #{@job.id} appears to be stuck at revision #{current_revision}"
        
        # git svn 프로세스가 실제로 실행 중인지 확인
        git_svn_running = check_git_svn_process_running
        
        unless git_svn_running
          Rails.logger.error "Job #{@job.id} git-svn process not found, marking as failed"
          @job.update!(
            status: 'failed',
            phase: 'cloning',
            error_log: @job.error_log.to_s + "\n[#{Time.current}] Process appears to be stuck at revision #{current_revision}, no git-svn process found"
          )
        end
      end
    else
      @last_revision_check = current_revision
      @same_revision_count = 0
    end
  end
  
  def check_git_svn_process_running
    # Docker 컨테이너 내에서 git svn 프로세스 확인
    ps_output = `ps aux | grep 'git svn' | grep -v grep`
    !ps_output.empty?
  rescue => e
    Rails.logger.error "Error checking git svn process: #{e.message}"
    false
  end
end