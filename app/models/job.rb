class Job < ApplicationRecord
  belongs_to :repository
  
  # Callbacks for cleanup
  after_destroy :cleanup_job_directory
  
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
  
  # User 관련 코드 제거
  
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
  
  def current_commit_message
    # 현재 처리 중인 커밋 메시지 (나중에 구현 가능)
    nil
  end
  
  def progress_percentage
    # First, use the progress field if it's set
    return progress.to_i if progress.present?
    
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
    # Use KST timezone
    Time.zone = 'Asia/Seoul' if Time.zone.nil?
    self.output_log += "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}\n"
    save
  end
  
  def append_error(message)
    self.error_log ||= ""
    # Use KST timezone
    Time.zone = 'Asia/Seoul' if Time.zone.nil?
    self.error_log += "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}\n"
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
    return false unless resumable? && (failed? || cancelled?)
    
    # Repository 설정이 변경되었는지 확인
    return false if repository_config_changed?
    
    true
  end
  
  # Repository 설정 변경 여부 확인
  def repository_config_changed?
    return false unless checkpoint_data.present? && checkpoint_data['repository_snapshot'].present?
    
    snapshot = checkpoint_data['repository_snapshot']
    
    # 중요한 설정들이 변경되었는지 확인
    current_config = {
      'authors_mapping' => repository.authors_mapping,
      'layout_type' => repository.layout_type,
      'custom_trunk_path' => repository.custom_trunk_path,
      'custom_branches_path' => repository.custom_branches_path,
      'custom_tags_path' => repository.custom_tags_path,
      'svn_structure' => repository.svn_structure
    }
    
    if snapshot != current_config
      append_output("경고: Repository 설정이 변경되어 재개할 수 없습니다.")
      append_output("변경된 설정으로 새로 시작하려면 Retry를 사용하세요.")
      true
    else
      false
    end
  end
  
  def can_delete?
    !active?  # 활성 상태가 아닌 경우만 삭제 가능
  end
  
  # Git 저장소 경로 가져오기
  def local_git_path
    # checkpoint_data에서 가져오기
    if checkpoint_data.present? && checkpoint_data['git_path'].present?
      checkpoint_data['git_path']
    # 또는 repository의 경로 사용
    elsif repository.local_git_path.present?
      repository.local_git_path
    # 기본 경로 생성
    else
      Rails.root.join('git_repos', "repository_#{repository_id}", "job_#{id}").to_s
    end
  end
  
  # 체크포인트 저장
  def save_checkpoint!(data = {})
    checkpoint = {
      timestamp: Time.current,
      phase: phase,
      phase_details: phase_details,
      git_path: repository.local_git_path,
      last_revision: current_revision,
      # Repository 설정 스냅샷 저장 (Resume 시 검증용)
      repository_snapshot: {
        'authors_mapping' => repository.authors_mapping,
        'layout_type' => repository.layout_type,
        'custom_trunk_path' => repository.custom_trunk_path,
        'custom_branches_path' => repository.custom_branches_path,
        'custom_tags_path' => repository.custom_tags_path,
        'svn_structure' => repository.svn_structure
      },
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
    # 이전 에러와 구분하기 위한 구분선 추가
    if error_log.present?
      self.error_log += "\n" + "="*60 + "\n"
      self.error_log += "[Resume at #{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')}]\n"
      self.error_log += "="*60 + "\n"
    end
    
    # Output 로그에도 구분선 추가
    if output_log.present?
      self.output_log += "\n" + "="*60 + "\n"
    end
    
    update!(
      status: 'running',
      started_at: Time.current,
      completed_at: nil  # 이전 완료 시간 리셋
    )
    
    append_output("작업 재개 중... (시도 #{retry_count}회차)")
    append_output("="*60)
  end
  
  private
  
  def cleanup_job_directory
    # Job별 디렉토리가 있으면 삭제
    if checkpoint_data && checkpoint_data['git_path'].present?
      git_path = checkpoint_data['git_path']
      
      # Job ID가 포함된 경로인지 확인 (Job별 디렉토리인 경우만 삭제)
      if git_path.include?("job_#{id}")
        if File.directory?(git_path)
          FileUtils.rm_rf(git_path)
          Rails.logger.info "Cleaned up job directory: #{git_path}"
        end
      end
    end
  rescue => e
    Rails.logger.error "Error cleaning up job directory: #{e.message}"
    # Don't prevent deletion even if cleanup fails
  end
end