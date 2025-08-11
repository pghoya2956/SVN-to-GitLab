module Api
  module V1
    class MigrationsController < ApiController
      # POST /api/v1/migrations
      # 
      # SVN to GitLab 마이그레이션 시작
      #
      # Parameters:
      #   svn_url: SVN 저장소 URL (required)
      #   gitlab_project_id: GitLab 프로젝트 ID (required)
      #   migration_method: 'simple' or 'full_history' (default: 'simple')
      #   auth_type: 'none', 'basic', 'ssh', 'token' (default: 'none')
      #   username: SVN 사용자명 (optional)
      #   password: SVN 비밀번호 (optional)
      #
      # Response:
      #   {
      #     "job": {
      #       "id": 123,
      #       "status": "pending",
      #       "progress": 0,
      #       "created_at": "2025-01-01T00:00:00Z"
      #     }
      #   }
      def create
        repository = current_user.repositories.create!(migration_params)
        
        # SVN 구조 감지 (백그라운드)
        if repository.full_history?
          # 백그라운드로 구조 감지 시작
          SvnStructureDetectionJob.perform_later(repository.id)
          # API 응답은 즉시 반환하고, 클라이언트가 상태를 폴링하도록 함
        end
        
        # 마이그레이션 작업 생성
        job = repository.jobs.create!(
          job_type: 'migration',
          status: 'pending',
          owner_token_hash: repository.owner_token_hash
        )
        
        # 백그라운드 작업 실행
        MigrationJob.perform_later(job.id)
        
        render json: { job: job_summary(job) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { 
          error: {
            code: 'validation_error',
            message: e.message,
            details: e.record.errors.details
          }
        }, status: :unprocessable_entity
      end
      
      # GET /api/v1/migrations/:job_id
      #
      # 마이그레이션 상태 조회
      def show
        job = current_user.jobs.find(params[:id])
        render json: { job: job_details(job) }
      rescue ActiveRecord::RecordNotFound
        render json: { 
          error: {
            code: 'not_found',
            message: 'Job not found'
          }
        }, status: :not_found
      end
      
      # GET /api/v1/migrations
      #
      # 마이그레이션 목록 조회
      def index
        jobs = current_user.jobs
        jobs = jobs.where(status: params[:status]) if params[:status].present?
        jobs = jobs.where(repository_id: params[:repository_id]) if params[:repository_id].present?
        
        page = params[:page] || 1
        per_page = [params[:per_page]&.to_i || 20, 100].min
        
        jobs = jobs.page(page).per(per_page)
        
        render json: {
          jobs: jobs.map { |job| job_summary(job) },
          meta: {
            current_page: jobs.current_page,
            total_pages: jobs.total_pages,
            total_count: jobs.total_count
          }
        }
      end
      
      # POST /api/v1/migrations/:job_id/cancel
      #
      # 마이그레이션 취소
      def cancel
        job = current_user.jobs.find(params[:id])
        
        if job.can_cancel?
          job.cancel!
          render json: { job: { id: job.id, status: job.status } }
        else
          render json: { 
            error: {
              code: 'invalid_state',
              message: "Cannot cancel job in #{job.status} state"
            }
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/v1/migrations/:job_id/logs
      #
      # 마이그레이션 로그 조회
      def logs
        job = current_user.jobs.find(params[:id])
        
        render json: {
          logs: {
            output: job.output_log || '',
            error: job.error_log || '',
            stages: job.stage_logs || []
          }
        }
      end
      
      private
      
      def migration_params
        params.require(:migration).permit(
          :svn_url, :gitlab_project_id, :migration_method,
          :auth_type, :username, :password, :branch_filter,
          :revision_limit, :name
        ).tap do |p|
          p[:name] ||= p[:svn_url].split('/').last
        end
      end
      
      def job_summary(job)
        {
          id: job.id,
          repository_name: job.repository.name,
          status: job.status,
          progress: job.progress,
          created_at: job.created_at.iso8601
        }
      end
      
      def job_details(job)
        {
          id: job.id,
          status: job.status,
          progress: job.progress,
          current_revision: job.current_revision,
          total_revisions: job.total_revisions,
          processing_speed: job.processing_speed,
          eta_seconds: job.eta_seconds,
          started_at: job.started_at&.iso8601,
          completed_at: job.completed_at&.iso8601,
          output_log: job.output_log&.last(1000),  # 최근 1000자만
          error_log: job.error_log
        }
      end
    end
  end
end