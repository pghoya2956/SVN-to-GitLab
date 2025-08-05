class Job < ApplicationRecord
  belongs_to :user
  belongs_to :repository
  
  # 상태 관리
  validates :status, inclusion: { in: %w[pending running completed failed cancelled] }
  validates :job_type, presence: true
  
  # 작업 단계 정의
  PHASES = {
    pending: '대기 중',
    cloning: 'SVN 저장소 클론 중',
    applying_strategy: '마이그레이션 전략 적용 중',
    pushing: 'GitLab에 푸시 중',
    completed: '완료'
  }.freeze
  
  validates :phase, inclusion: { in: PHASES.keys.map(&:to_s) }, allow_nil: true
  
  default_scope { where(user_id: User.current.id) if User.current }
  
  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: %w[pending running]) }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  
  def pending?
    status == 'pending'
  end
  
  def running?
    status == 'running'
  end
  
  def completed?
    status == 'completed'
  end
  
  def failed?
    status == 'failed'
  end
  
  def cancelled?
    status == 'cancelled'
  end
  
  def active?
    pending? || running?
  end
  
  def finished?
    completed? || failed? || cancelled?
  end
  
  def duration
    return nil unless started_at
    end_time = completed_at || Time.current
    end_time - started_at
  end
  
  def formatted_duration
    return '-' unless duration
    
    seconds = duration.to_i
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60
    
    if hours > 0
      "#{hours}시간 #{minutes}분"
    elsif minutes > 0
      "#{minutes}분 #{secs}초"
    else
      "#{secs}초"
    end
  end
  
  # 진행률 계산
  def calculate_progress
    return 0 unless current_revision && total_revisions && total_revisions > 0
    [(current_revision.to_f / total_revisions * 100).round(1), 100].min
  end
  
  # 진행률 업데이트
  def update_progress!
    update!(progress: calculate_progress)
  end
  
  def formatted_eta
    return '계산 중...' unless eta_seconds && eta_seconds > 0
    
    hours = (eta_seconds / 3600).to_i
    minutes = ((eta_seconds % 3600) / 60).to_i
    secs = (eta_seconds % 60).to_i
    
    if hours > 0
      "#{hours}시간 #{minutes}분"
    elsif minutes > 0
      "#{minutes}분 #{secs}초"
    else
      "#{secs}초"
    end
  end
  
  def progress_percentage
    # First, use the progress field if it's set
    return progress if progress.present?
    
    # Otherwise, calculate from commits if possible
    return 0 if total_commits.to_i == 0
    ((processed_commits.to_f / total_commits) * 100).round
  end
  
  def parsed_parameters
    JSON.parse(parameters || '{}')
  rescue JSON::ParserError
    {}
  end
  
  def append_output(message)
    self.output_log ||= ""
    self.output_log += "[#{Time.current.strftime('%Y-%m-%d %H:%M:%S')}] #{message}\n"
    save
  end
  
  def append_error(message)
    self.error_log ||= ""
    self.error_log += "[#{Time.current.strftime('%Y-%m-%d %H:%M:%S')}] #{message}\n"
    save
  end
  
  def mark_as_running!
    update!(status: 'running', started_at: Time.current)
  end
  
  def mark_as_completed!(result_url = nil)
    update!(
      status: 'completed',
      completed_at: Time.current,
      progress: 100,
      result_url: result_url
    )
  end
  
  def mark_as_failed!(error_message = nil)
    append_error(error_message) if error_message
    update!(status: 'failed', completed_at: Time.current)
  end
  
  def cancel!
    if active? && sidekiq_job_id.present?
      # Cancel Sidekiq job if running
      require 'sidekiq/api'
      
      # Check scheduled jobs
      scheduled_set = Sidekiq::ScheduledSet.new
      scheduled_job = scheduled_set.find { |job| job.jid == sidekiq_job_id }
      scheduled_job&.delete
      
      # Check retry set
      retry_set = Sidekiq::RetrySet.new
      retry_job = retry_set.find { |job| job.jid == sidekiq_job_id }
      retry_job&.delete
      
      # Check processing jobs
      workers = Sidekiq::Workers.new
      worker = workers.find do |_process_id, _thread_id, work|
        # Sidekiq::Work object has different interface in newer versions
        # Access the hash directly via instance variable
        work_hash = work.instance_variable_get(:@hsh)
        if work_hash && work_hash['payload']
          payload = JSON.parse(work_hash['payload']) rescue nil
          payload && payload['jid'] == sidekiq_job_id
        end
      end
      
      if worker
        # Can't directly cancel running job, but we can mark it for cancellation
        append_output("Cancellation requested. Job will stop at next checkpoint.")
      end
    end
    
    update!(status: 'cancelled', completed_at: Time.current)
  end
  
  # 재개 가능 여부 확인
  def can_resume?
    resumable? && 
    (failed? || cancelled?) && 
    retry_count < 3 &&
    repository.local_git_path.present? &&
    File.exist?(repository.local_git_path)
  end
  
  # 체크포인트 저장
  def save_checkpoint!(data = {})
    checkpoint = {
      timestamp: Time.current,
      phase: phase,
      phase_details: phase_details,
      git_path: repository.local_git_path,
      last_revision: current_revision,
      additional_data: data
    }
    
    update!(
      checkpoint_data: checkpoint,
      resumable: true
    )
  end
  
  # 단계 업데이트
  def update_phase!(new_phase, details = {})
    update!(
      phase: new_phase,
      phase_details: details
    )
    append_output("단계 변경: #{PHASES[new_phase.to_sym]}")
  end
  
  # 재개 시작
  def start_resume!
    update!(
      status: 'running',
      retry_count: retry_count + 1,
      started_at: Time.current
    )
    append_output("작업 재개 중... (시도 #{retry_count}/3)")
  end
end