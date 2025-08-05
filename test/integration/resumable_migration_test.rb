require 'test_helper'

class ResumableMigrationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @repository = repositories(:one)
    @repository.update!(
      gitlab_project_id: 12345,
      migration_method: 'git-svn',
      standard_layout: true
    )
    sign_in @user
  end

  test "can resume failed migration job" do
    # 1. 실패한 Job 생성 (cloning 단계에서 실패)
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      phase: 'cloning',
      resumable: true,
      retry_count: 0,
      checkpoint_data: {
        timestamp: Time.current,
        last_revision: 1500,
        git_path: '/app/git_repos/test'
      }
    )
    
    # 2. Job 상세 페이지 방문
    get job_path(job)
    assert_response :success
    
    # Resume 버튼 확인
    assert_select "a[href='#{resume_job_path(job)}']", text: /Resume Migration/
    assert_select ".alert-info", text: /이 작업은 재개 가능합니다/
    assert_select ".phase-progress"
    
    # 3. Resume 액션 실행
    assert_difference 'job.reload.retry_count', 1 do
      post resume_job_path(job)
    end
    
    assert_redirected_to job_path(job)
    follow_redirect!
    
    assert_match /마이그레이션이 마지막 체크포인트에서 재개되었습니다/, flash[:notice]
  end
  
  test "cannot resume non-resumable job" do
    # 재개 불가능한 Job
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      resumable: false
    )
    
    get job_path(job)
    assert_response :success
    
    # Resume 버튼이 없어야 함
    assert_select "a[href='#{resume_job_path(job)}']", count: 0
    
    # 직접 POST 시도
    post resume_job_path(job)
    assert_redirected_to job_path(job)
    follow_redirect!
    
    assert_match /이 작업은 재개할 수 없습니다/, flash[:alert]
  end
  
  test "cannot resume after max retry attempts" do
    # 최대 재시도 횟수 초과
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      resumable: true,
      retry_count: 3,
      phase: 'cloning'
    )
    
    get job_path(job)
    assert_response :success
    
    # Resume 버튼이 없어야 함
    assert_select "a[href='#{resume_job_path(job)}']", count: 0
  end
  
  test "phase progress shows correct status for each phase" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'running',
      phase: 'applying_strategy',
      phase_details: {
        progress_percentage: 65
      }
    )
    
    get job_path(job)
    assert_response :success
    
    # Phase progress 컴포넌트 확인
    assert_select ".phase-progress" do
      # cloning은 완료됨
      assert_select ".phase-item.completed", minimum: 1
      # applying_strategy는 현재 진행 중
      assert_select ".phase-item.current", 1
      # 진행률 표시
      assert_select ".phase-detail", text: /65%/
    end
  end
  
  test "checkpoint data displayed for failed jobs" do
    checkpoint_time = Time.current
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      phase: 'pushing',
      resumable: true,
      checkpoint_data: {
        timestamp: checkpoint_time,
        last_revision: 2500
      }
    )
    
    get job_path(job)
    assert_response :success
    
    # 체크포인트 정보 표시 확인
    assert_select ".bg-light" do
      assert_select "small", text: /마지막 체크포인트/
      assert_select "small", text: /리비전 2500/
    end
  end
end