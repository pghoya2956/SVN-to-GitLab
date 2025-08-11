require 'open3'

class JobsController < ApplicationController
  before_action :set_job, only: [:show, :cancel, :resume, :retry, :logs, :destroy, :push_to_gitlab]
  before_action :set_repository, only: [:new, :create]
  
  def index
    repository_ids = Repository.for_token(current_token_hash).pluck(:id)
    
    # Job Type에 따라 필터링
    @jobs = Job.where(repository_id: repository_ids).includes(:repository)
    
    if params[:job_type] == 'structure_detection'
      # 구조 감지 탭을 선택한 경우
      @jobs = @jobs.where(job_type: 'structure_detection')
    elsif params[:job_type].present?
      # 특정 job_type 필터링
      @jobs = @jobs.where(job_type: params[:job_type])
    else
      # 전체 탭 - 구조 감지는 제외
      @jobs = @jobs.where.not(job_type: 'structure_detection')
    end
    
    @jobs = @jobs.recent
    
    # 각 타입별 카운트
    @job_counts = {
      all: Job.where(repository_id: repository_ids).where.not(job_type: 'structure_detection').count,
      migration: Job.where(repository_id: repository_ids, job_type: 'migration').count,
      incremental_sync: Job.where(repository_id: repository_ids, job_type: 'incremental_sync').count,
      structure_detection: Job.where(repository_id: repository_ids, job_type: 'structure_detection').count
    }
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
      # clear_logs 파라미터가 있으면 에러 로그 초기화
      if params[:clear_logs] == 'true'
        @job.update(error_log: "[Logs cleared at #{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S')}]\n")
        @job.append_output("[Previous error logs cleared for fresh start]")
      end
      
      # 재시도 카운트 증가 및 상태 초기화
      @job.increment!(:retry_count)
      @job.update!(completed_at: nil)  # 이전 완료 시간 제거
      
      # 새로운 Sidekiq job 시작 (토큰 정보 포함)
      job_id = MigrationJob.perform_async(@job.id, session[:gitlab_token], session[:gitlab_endpoint])
      @job.update(sidekiq_job_id: job_id)
      
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
      # Job에서 repository 가져오기
      repository = @job.repository
      
      # 새 Job 생성 (완전히 새로운 시작)
      new_job_params = {
        repository_id: repository.id,
        job_type: @job.job_type,
        owner_token_hash: repository.owner_token_hash,
        status: 'pending',
        parameters: @job.parameters,
        total_revisions: @job.total_revisions
      }
      
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
  
  def push_to_gitlab
    # 검증
    unless @job.job_type == 'migration'
      redirect_to @job, alert: "Migration Job만 Push 가능합니다."
      return
    end
    
    # 마이그레이션이 충분히 진행되었는지 확인 (최소한 cloning 완료)
    unless @job.phase.present? && ['applying_strategy', 'pushing', 'completed'].include?(@job.phase)
      redirect_to @job, alert: "마이그레이션이 충분히 진행되지 않았습니다. SVN 클론이 완료된 후에 Push가 가능합니다."
      return
    end
    
    unless @job.local_git_path.present? && File.directory?(@job.local_git_path)
      redirect_to @job, alert: "로컬 Git 저장소를 찾을 수 없습니다."
      return
    end
    
    # Git 저장소가 유효한지 추가 검증
    Dir.chdir(@job.local_git_path) do
      unless File.exist?('.git')
        redirect_to @job, alert: "유효한 Git 저장소가 아닙니다."
        return
      end
      
      # 최소한 하나의 커밋이 있는지 확인
      commit_count = `git rev-list --count --all 2>/dev/null`.strip.to_i
      if commit_count == 0
        redirect_to @job, alert: "Git 저장소에 커밋이 없습니다. 마이그레이션이 제대로 완료되지 않았습니다."
        return
      end
    end
    
    unless @job.repository.gitlab_project_id.present?
      redirect_to @job, alert: "GitLab 프로젝트가 설정되지 않았습니다."
      return
    end
    
    begin
      # Push 시작 로그
      @job.append_output("\n" + "="*60)
      @job.append_output("수동 Push 시작: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}")
      @job.append_output("="*60)
      
      # GitLab 커넥터 생성
      connector = Repositories::GitlabConnector.new(
        session[:gitlab_token], 
        session[:gitlab_endpoint] || 'https://gitlab.com/api/v4'
      )
      
      # GitLab 프로젝트 정보 가져오기
      project = connector.fetch_project(@job.repository.gitlab_project_id)
      unless project[:success]
        raise "GitLab 프로젝트 조회 실패: #{project[:errors].join(', ')}"
      end
      
      gitlab_url = project[:project][:http_url_to_repo]
      push_url = gitlab_url.sub('https://', "https://oauth2:#{session[:gitlab_token]}@")
      
      # Git 저장소로 이동하여 Push 실행
      Dir.chdir(@job.local_git_path) do
        # Remote 확인 및 설정
        remotes = `git remote`.split("\n")
        if remotes.include?('gitlab')
          # 기존 remote 업데이트
          system('git', 'remote', 'set-url', 'gitlab', gitlab_url)
          @job.append_output("GitLab remote URL 업데이트됨")
        else
          # 새 remote 추가
          system('git', 'remote', 'add', 'gitlab', gitlab_url)
          @job.append_output("GitLab remote 추가됨")
        end
        
        # 현재 브랜치 확인
        current_branch = `git branch --show-current`.strip
        @job.append_output("현재 브랜치: #{current_branch}")
        
        if current_branch.empty?
          # detached HEAD 상태일 경우 master 브랜치 생성
          system('git', 'checkout', '-b', 'master')
          current_branch = 'master'
          @job.append_output("master 브랜치 생성됨")
        end
        
        # Target branch 확인
        target_branch = @job.repository.gitlab_target_branch.presence || 'main'
        @job.append_output("GitLab target 브랜치: #{target_branch}")
        
        # Push 실행
        @job.append_output("\nPush 시작...")
        push_output = []
        push_success = false
        
        Open3.popen3('git', 'push', '-u', push_url, "#{current_branch}:#{target_branch}", '--force') do |stdin, stdout, stderr, wait_thr|
          stdout.each_line { |line| push_output << line.strip }
          stderr.each_line { |line| push_output << line.strip }
          push_success = wait_thr.value.success?
        end
        
        push_output.each { |line| @job.append_output("  #{line}") }
        
        if push_success
          @job.append_output("\n✅ Push 성공!")
          # Push 성공 시 Job 상태와 phase 업데이트
          @job.update(
            result_url: project[:project][:web_url],
            phase: 'completed',
            status: 'completed',
            completed_at: Time.current,
            progress: 100
          )
          @job.append_output("마이그레이션이 완전히 완료되었습니다.")
          redirect_to @job, notice: "GitLab Push가 성공적으로 완료되었습니다."
        else
          @job.append_error("Push 실패: #{push_output.join('\n')}")
          redirect_to @job, alert: "GitLab Push 실패. 로그를 확인하세요."
        end
      end
      
    rescue => e
      @job.append_error("수동 Push 오류: #{e.message}")
      redirect_to @job, alert: "Push 중 오류 발생: #{e.message}"
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
  
  def build_job_parameters(repository = nil)
    repository ||= @repository
    
    return {} unless repository
    
    {
      repository_id: repository.id,
      migration_type: repository.migration_type,
      preserve_history: repository.preserve_history,
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
      started_at: @job.started_at&.strftime("%Y-%m-%d %H:%M"),
      completed_at: @job.completed_at&.strftime("%Y-%m-%d %H:%M"),
      result_url: @job.result_url,
      last_output: @job.output_log&.lines&.last(5)&.join,
      has_errors: @job.error_log.present?
    }
  end
end