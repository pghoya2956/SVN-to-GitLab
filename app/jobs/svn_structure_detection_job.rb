class SvnStructureDetectionJob < ApplicationJob
  queue_as :default
  
  def perform(repository_id)
    repository = Repository.find(repository_id)
    
    # 이미 감지 중인지 확인
    return if repository.jobs.where(job_type: 'structure_detection', status: ['pending', 'running']).exists?
    
    # Job 레코드 생성
    job = repository.jobs.create!(
      job_type: 'structure_detection',
      status: 'running',
      started_at: Time.current,
      description: 'SVN 구조 감지 중...'
    )
    
    begin
      # SVN 구조 감지 실행
      detector = Repositories::SvnStructureDetector.new(repository, job)
      result = detector.call
      
      if result[:success]
        # layout_type 매핑
        layout_type_mapping = {
          'standard' => 'standard',
          'partial_standard' => 'custom',
          'non_standard' => 'custom'
        }
        
        # Repository 업데이트
        repository.update!(
          svn_structure: result[:structure],
          authors_mapping: result[:authors],
          layout_type: layout_type_mapping[result[:structure][:layout]] || 'custom',
          latest_revision: result[:stats][:latest_revision],
          total_revisions: result[:total_revisions] || result[:stats][:latest_revision],
          last_detected_at: Time.current
        )
        
        # Job 성공 처리
        job.update!(
          status: 'completed',
          completed_at: Time.current,
          progress: 100,
          output_log: job.output_log.to_s + "\n\n✅ SVN 구조 감지 완료!\n" +
                     "레이아웃: #{result[:structure][:layout]}\n" +
                     "작성자 수: #{result[:authors].size}명\n" +
                     "총 리비전: #{result[:total_revisions]}"
        )
        
        # ActionCable로 완료 알림
        broadcast_completion(repository, result)
      else
        # Job 실패 처리
        job.update!(
          status: 'failed',
          completed_at: Time.current,
          error_log: result[:error]
        )
        
        # ActionCable로 실패 알림
        broadcast_failure(repository, result[:error])
      end
    rescue => e
      # 예외 발생 시 처리
      job.update!(
        status: 'failed',
        completed_at: Time.current,
        error_log: "예외 발생: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
      )
      
      broadcast_failure(repository, e.message)
      raise # 재시도를 위해 예외 재발생
    end
  end
  
  private
  
  def broadcast_completion(repository, result)
    ActionCable.server.broadcast(
      "repository_#{repository.id}",
      {
        type: 'structure_detection_complete',
        success: true,
        structure: result[:structure],
        authors_count: result[:authors].size,
        total_revisions: result[:total_revisions],
        message: "SVN 구조 감지가 완료되었습니다!"
      }
    )
  end
  
  def broadcast_failure(repository, error)
    ActionCable.server.broadcast(
      "repository_#{repository.id}",
      {
        type: 'structure_detection_failed',
        success: false,
        error: error,
        message: "SVN 구조 감지 실패: #{error}"
      }
    )
  end
end