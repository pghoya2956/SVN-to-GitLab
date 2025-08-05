class JobsController < ApplicationController
  before_action :set_job, only: [:show, :cancel, :resume, :logs]
  before_action :set_repository, only: [:new, :create]
  
  def index
    @jobs = current_user.jobs.includes(:repository).recent
  end
  
  def show
    respond_to do |format|
      format.html
      format.json { render json: job_status_json }
    end
  end
  
  def new
    @job = @repository.jobs.build(user: current_user)
    
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
    @job.user = current_user
    @job.job_type = 'migration'
    @job.parameters = build_job_parameters.to_json
    
    if @job.save
      # Queue Sidekiq job
      job_id = MigrationJob.perform_async(@job.id)
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
      
      # 새로운 Sidekiq job 시작
      job_id = MigrationJob.perform_async(@job.id)
      @job.update(sidekiq_job_id: job_id)
      
      redirect_to @job, notice: "마이그레이션이 마지막 체크포인트에서 재개되었습니다."
    else
      redirect_to @job, alert: "이 작업은 재개할 수 없습니다."
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
    @job = current_user.jobs.find(params[:id])
  end
  
  def set_repository
    @repository = current_user.repositories.find(params[:repository_id])
  end
  
  def job_params
    params.require(:job).permit(:description)
  end
  
  def build_job_parameters
    {
      repository_id: @repository.id,
      migration_type: @repository.migration_type,
      preserve_history: @repository.preserve_history,
      branch_strategy: @repository.branch_strategy,
      tag_strategy: @repository.tag_strategy,
      started_by: current_user.email
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