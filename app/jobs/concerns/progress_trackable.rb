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
        
        sleep 5
      end
    rescue => e
      Rails.logger.error "Progress tracking error: #{e.message}"
    end
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
    
    # Job 모델 업데이트
    @job.update!(
      progress: data[:progress_percentage].to_i,
      current_revision: data[:current_revision],
      total_revisions: data[:total_revisions],
      processing_speed: data[:processing_speed],
      eta_seconds: data[:eta] == "계산 중..." ? nil : parse_duration_to_seconds(data[:eta])
    )
  end
  
  def get_current_revision
    return 0 unless @repository.local_git_path && File.directory?(@repository.local_git_path)
    
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
  rescue => e
    Rails.logger.error "Error getting current revision: #{e.message}"
    0
  end
  
  def get_current_commit_message
    return nil unless @repository.local_git_path && File.directory?(@repository.local_git_path)
    
    Dir.chdir(@repository.local_git_path) do
      `git log -1 --pretty=format:'%s' 2>/dev/null`.strip
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
    return nil if duration_str == "계산 중..."
    
    total_seconds = 0
    
    if match = duration_str.match(/(\d+)시간/)
      total_seconds += match[1].to_i * 3600
    end
    
    if match = duration_str.match(/(\d+)분/)
      total_seconds += match[1].to_i * 60
    end
    
    if match = duration_str.match(/(\d+)초/)
      total_seconds += match[1].to_i
    end
    
    total_seconds
  end
  
  def job_running?
    @job.reload.status == 'running'
  end
end