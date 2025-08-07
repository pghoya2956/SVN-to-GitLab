class JobsController < ApplicationController
  before_action :set_job, only: [:show, :cancel, :resume, :retry, :logs, :destroy]
  before_action :set_repository, only: [:new, :create]
  
  def index
    repository_ids = Repository.for_token(current_token_hash).pluck(:id)
    @jobs = Job.where(repository_id: repository_ids).includes(:repository).recent
  end
  
  def show
    respond_to do |format|
      format.html
      format.json { render json: job_status_json }
    end
  end
  
  def new
    @job = @repository.jobs.build
    
    # Check prerequisites
    unless @repository.gitlab_project_id.present?
      redirect_to @repository, alert: "Please select a GitLab target project first"
      return
    end
    
    unless @repository.migration_type.present?
      redirect_to edit_strategy_repository_path(@repository), 
                  alert: "Please configure migration strategy first"
      return
    end
  end
  
  def create
    # Check for active jobs
    if @repository.has_active_job?
      redirect_to @repository, alert: "This repository already has an active job running."
      return
    end
    
    @job = @repository.jobs.build(job_params)
    @job.owner_token_hash = current_token_hash
    @job.job_type = 'migration'
    @job.parameters = build_job_parameters.to_json
    
    # Repository에서 정보 복사
    if @repository.total_revisions.present?
      @job.total_revisions = @repository.total_revisions
    end
    
    if @job.save
      # Queue Sidekiq job with token
      job_id = MigrationJob.perform_async(@job.id, session[:gitlab_token], session[:gitlab_endpoint])
      @job.update(sidekiq_job_id: job_id)
      
      redirect_to @job, notice: "Migration job started successfully"
    else
      render :new, status: :unprocessable_entity
    end
  end
  
  def cancel
    if @job.active?
      @job.cancel!
      redirect_to @job, notice: "Job cancellation requested"
    else
      redirect_to @job, alert: "Cannot cancel a #{@job.status} job"
    end
  end
  
  def resume
    if @job.can_resume?
      # 재시도 카운트 증가
      @job.increment!(:retry_count)
      
      # 새로운 Sidekiq job 시작 (토큰 정보 포함)
      job_id = MigrationJob.perform_async(@job.id, session[:gitlab_token], session[:gitlab_endpoint])
      @job.update(sidekiq_job_id: job_id, status: 'pending')
      
      redirect_to @job, notice: "마이그레이션이 마지막 체크포인트에서 재개되었습니다."
    elsif @job.repository_config_changed?
      redirect_to @job, alert: "Repository 설정이 변경되어 재개할 수 없습니다. Retry를 사용하여 새로 시작하세요."
    else
      redirect_to @job, alert: "이 작업은 재개할 수 없습니다."
    end
  end
  
  # Retry 액션 추가 (Resume과 달리 처음부터 다시 시작)
  def retry
    if @job.failed? || @job.cancelled?
      # 새 Job 생성 (완전히 새로운 시작)
      new_job_params = build_job_parameters.merge(
        repository_id: @repository.id,
        job_type: @job.job_type
      )
      
      new_job = Job.create!(new_job_params)
      
      # 새 Sidekiq job 시작
      job_id = MigrationJob.perform_async(new_job.id, session[:gitlab_token], session[:gitlab_endpoint])
      new_job.update(sidekiq_job_id: job_id)
      
      # 원래 Job에 재시도 정보 기록
      @job.append_output("새 Job ##{new_job.id}으로 재시도됨")
      
      redirect_to new_job, notice: "새로운 Job으로 마이그레이션을 처음부터 다시 시작합니다."
    else
      redirect_to @job, alert: "이 작업은 다시 시작할 수 없습니다."
    end
  end
  
  def destroy
    if @job.can_delete?
      @repository = @job.repository
      @job.destroy
      redirect_to @repository, notice: "Job이 성공적으로 삭제되었습니다."
    else
      redirect_to @job, alert: "진행 중인 Job은 삭제할 수 없습니다. 먼저 취소해주세요."
    end
  end
  
  def logs
    respond_to do |format|
      format.text do
        logs = "=== OUTPUT LOG ===\n"
        logs += @job.output_log || "No output yet\n"
        logs += "\n\n=== ERROR LOG ===\n"
        logs += @job.error_log || "No errors\n"
        
        render plain: logs
      end
      format.json do
        render json: {
          output_log: @job.output_log,
          error_log: @job.error_log
        }
      end
    end
  end
  
  private
  
  def set_job
    repository_ids = Repository.for_token(current_token_hash).pluck(:id)
    @job = Job.where(repository_id: repository_ids).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to jobs_path, alert: "Job not found or access denied"
  end
  
  def set_repository
    @repository = Repository.for_token(current_token_hash).find(params[:repository_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to repositories_path, alert: "Repository not found or access denied"
  end
  
  def job_params
    params.require(:job).permit(:description)
  end
  
  def build_job_parameters
    {
      repository_id: @repository.id,
      migration_type: @repository.migration_type,
      preserve_history: @repository.preserve_history,
      started_by: current_gitlab_user&.dig(:email) || 'GitLab User'
    }
  end
  
  def job_status_json
    {
      id: @job.id,
      status: @job.status,
      progress: @job.progress_percentage,
      processed_commits: @job.processed_commits,
      total_commits: @job.total_commits,
      processed_files: @job.processed_files,
      total_files: @job.total_files,
      current_revision: @job.current_revision,
      total_revisions: @job.total_revisions,
      processing_speed: @job.processing_speed,
      eta_seconds: @job.eta_seconds,
      duration: @job.formatted_duration,
      formatted_eta: @job.formatted_eta,
      started_at: @job.started_at,
      completed_at: @job.completed_at,
      result_url: @job.result_url,
      last_output: @job.output_log&.lines&.last(5)&.join,
      has_errors: @job.error_log.present?
    }
  end
end