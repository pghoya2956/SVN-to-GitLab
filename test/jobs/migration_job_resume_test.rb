require 'test_helper'

class MigrationJobResumeTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
    @repository = repositories(:one)
    @repository.update!(
      gitlab_project_id: 12345,
      migration_method: 'git-svn',
      standard_layout: true,
      svn_url: 'https://svn.example.com/repo'
    )
    
    # GitLab token 설정
    @user.create_gitlab_token!(encrypted_token: Base64.encode64('test-token'))
    User.current = @user
  end
  
  teardown do
    User.current = nil
  end
  
  test "should_resume? returns true for resumable job" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      phase: 'cloning',
      checkpoint_data: { timestamp: Time.current },
      local_git_path: '/app/git_repos/test'
    )
    
    # File.exist? mock
    File.stub :exist?, true do
      migration_job = MigrationJob.new
      migration_job.instance_variable_set(:@job, job)
      migration_job.instance_variable_set(:@repository, @repository)
      
      assert migration_job.send(:should_resume?)
    end
  end
  
  test "should_resume? returns false for pending job" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'pending',
      phase: 'pending'
    )
    
    migration_job = MigrationJob.new
    migration_job.instance_variable_set(:@job, job)
    migration_job.instance_variable_set(:@repository, @repository)
    
    assert_not migration_job.send(:should_resume?)
  end
  
  test "resume_migration calls correct resume method based on phase" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'failed',
      phase: 'cloning',
      resumable: true,
      checkpoint_data: { timestamp: Time.current }
    )
    
    migration_job = MigrationJob.new
    migration_job.instance_variable_set(:@job, job)
    migration_job.instance_variable_set(:@repository, @repository)
    
    # Mock resume_cloning
    migration_job.stub :track_progress, nil do
      migration_job.stub :resume_cloning, nil do
        migration_job.send(:resume_migration)
        
        assert_equal 'running', job.reload.status
        assert_match /이전 작업을 재개합니다/, job.output_log
      end
    end
  end
  
  test "handle_job_error marks resumable errors correctly" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'running',
      phase: 'cloning'
    )
    
    migration_job = MigrationJob.new
    migration_job.instance_variable_set(:@job, job)
    
    # 네트워크 에러 (재개 가능)
    network_error = StandardError.new("Connection timed out")
    migration_job.send(:handle_job_error, network_error)
    
    assert job.reload.resumable?
    assert_equal({ "error_type" => "resumable" }, job.phase_details)
    
    # 인증 에러 (재개 불가능)
    auth_error = StandardError.new("Authentication failed")
    job.update!(resumable: false) # Reset
    migration_job.send(:handle_job_error, auth_error)
    
    assert_not job.reload.resumable?
    assert_equal({ "error_type" => "fatal" }, job.phase_details)
  end
  
  test "save_checkpoint creates proper checkpoint data" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'running',
      phase: 'cloning',
      current_revision: 1234,
      processed_commits: 100,
      total_commits: 500
    )
    
    job.save_checkpoint!(
      last_revision: 1234,
      additional_field: 'test'
    )
    
    checkpoint = job.checkpoint_data
    assert checkpoint['timestamp'].present?
    assert_equal 'cloning', checkpoint['phase']
    assert_equal '/app/git_repos/test', checkpoint['git_path']
    assert_equal 1234, checkpoint['last_revision']
    assert_equal 'test', checkpoint['additional_data']['additional_field']
  end
  
  test "update_phase! updates phase and triggers checkpoint" do
    job = @repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'running'
    )
    
    job.update_phase!('cloning')
    
    assert_equal 'cloning', job.phase
    assert job.phase_details['start_time'].present?
    assert job.checkpoint_data.present?
  end
end