module ResumableErrors
  extend ActiveSupport::Concern
  
  # 재개 가능한 에러 패턴
  RESUMABLE_ERROR_PATTERNS = [
    /Connection timed out/i,
    /Network is unreachable/i,
    /Connection reset by peer/i,
    /Temporary failure/i,
    /Could not resolve host/i,
    /Operation timed out/i,
    /Connection refused/i,
    /504 Gateway Time-out/i,
    /503 Service Unavailable/i,
    /429 Too Many Requests/i,
    /Disk quota exceeded/i,
    /No space left on device/i
  ].freeze
  
  # 치명적 에러 패턴 (재개 불가)
  FATAL_ERROR_PATTERNS = [
    /Authentication failed/i,
    /Permission denied/i,
    /Repository not found/i,
    /Invalid repository/i,
    /Corrupted repository/i,
    /Invalid URL/i,
    /Access denied/i,
    /Bad credentials/i,
    /Unauthorized/i,
    /403 Forbidden/i,
    /404 Not Found/i
  ].freeze
  
  included do
    # 에러 처리 래퍼
    def handle_job_error(error)
      error_message = error.message
      
      if resumable_error?(error_message)
        handle_resumable_error(error)
      else
        handle_fatal_error(error)
      end
      
      raise error
    end
    
    private
    
    def resumable_error?(message)
      return false if fatal_error?(message)
      
      RESUMABLE_ERROR_PATTERNS.any? { |pattern| message =~ pattern }
    end
    
    def fatal_error?(message)
      FATAL_ERROR_PATTERNS.any? { |pattern| message =~ pattern }
    end
    
    def handle_resumable_error(error)
      @job.append_error("재개 가능한 오류 발생: #{error.message}")
      @job.update!(resumable: true)
      
      # 현재 상태 체크포인트 저장
      @job.save_checkpoint!(
        error_type: 'resumable',
        error_message: error.message,
        error_time: Time.current
      )
      
      Rails.logger.warn "Resumable error for job #{@job.id}: #{error.message}"
    end
    
    def handle_fatal_error(error)
      @job.append_error("치명적 오류 발생: #{error.message}")
      @job.update!(resumable: false)
      
      Rails.logger.error "Fatal error for job #{@job.id}: #{error.message}"
    end
  end
end