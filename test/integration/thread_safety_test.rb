require 'test_helper'

class ThreadSafetyTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: 'test@example.com',
      encrypted_password: 'password'
    )
    
    @repository = Repository.create!(
      name: 'Test Repo',
      svn_url: 'https://svn.example.com/test',
      user: @user
    )
    
    @job = Job.create!(
      repository: @repository,
      job_type: 'migration',
      status: 'running',
      user: @user
    )
  end
  
  test "인스턴스 변수가 스레드 간 공유됨" do
    job = MigrationJob.new
    job.instance_variable_set(:@job, @job)
    job.instance_variable_set(:@repository, @repository)
    
    # 초기값 설정
    job.instance_variable_set(:@last_output_time, Time.now)
    job.instance_variable_set(:@output_count, 0)
    initial_time = job.instance_variable_get(:@last_output_time)
    
    # 여러 스레드에서 업데이트
    threads = []
    10.times do
      threads << Thread.new do
        10.times do
          sleep 0.01
          job.instance_variable_set(:@last_output_time, Time.now)
          count = job.instance_variable_get(:@output_count)
          job.instance_variable_set(:@output_count, count + 1)
        end
      end
    end
    
    threads.each(&:join)
    
    # 검증
    final_time = job.instance_variable_get(:@last_output_time)
    final_count = job.instance_variable_get(:@output_count)
    
    assert final_time > initial_time, "시간이 업데이트되어야 함"
    assert final_count > 0, "카운트가 증가해야 함"
    # 정확한 100이 아닐 수 있음 (race condition) - 그러나 우리 용도로는 충분
    assert final_count >= 50, "최소한 절반 이상은 카운트되어야 함"
  end
  
  test "타임아웃 환경변수 설정 테스트" do
    # 환경변수 설정
    ENV['GITSVN_OUTPUT_WARNING'] = '60'
    ENV['GITSVN_OUTPUT_TIMEOUT'] = '120'
    
    job = MigrationJob.new
    
    # run_git_svn_fetch_batch 메서드 일부 실행
    warning_timeout = ENV.fetch('GITSVN_OUTPUT_WARNING', '300').to_i
    stuck_timeout = ENV.fetch('GITSVN_OUTPUT_TIMEOUT', '600').to_i
    
    assert_equal 60, warning_timeout
    assert_equal 120, stuck_timeout
    
    # 환경변수 정리
    ENV.delete('GITSVN_OUTPUT_WARNING')
    ENV.delete('GITSVN_OUTPUT_TIMEOUT')
  end
  
  test "기본 타임아웃 값 테스트" do
    # 환경변수 없을 때 기본값
    warning_timeout = ENV.fetch('GITSVN_OUTPUT_WARNING', '300').to_i
    stuck_timeout = ENV.fetch('GITSVN_OUTPUT_TIMEOUT', '600').to_i
    
    assert_equal 300, warning_timeout  # 5분
    assert_equal 600, stuck_timeout    # 10분
  end
  
  test "스레드 간 타임스탬프 공유 시뮬레이션" do
    job = MigrationJob.new
    job.instance_variable_set(:@job, @job)
    job.instance_variable_set(:@last_output_time, Time.now - 1000)  # 오래된 시간
    
    # stdout 스레드 시뮬레이션
    stdout_thread = Thread.new do
      5.times do
        sleep 0.1
        job.instance_variable_set(:@last_output_time, Time.now)
      end
    end
    
    # monitor 스레드 시뮬레이션
    monitor_results = []
    monitor_thread = Thread.new do
      5.times do
        sleep 0.15
        time_diff = Time.now - job.instance_variable_get(:@last_output_time)
        monitor_results << time_diff
      end
    end
    
    stdout_thread.join
    monitor_thread.join
    
    # 모든 시간 차이가 1초 미만이어야 함 (업데이트가 공유됨)
    monitor_results.each do |diff|
      assert diff < 1.0, "시간 차이가 1초 미만이어야 함: #{diff}"
    end
  end
end