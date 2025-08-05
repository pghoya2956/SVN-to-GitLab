namespace :test do
  desc "SVN to GitLab 마이그레이션 계층적 테스트"
  task migration: :environment do
    require 'benchmark'
    
    # 테스트 설정
    test_user_email = ENV['TEST_USER_EMAIL'] || 'test@example.com'
    test_user_password = ENV['TEST_USER_PASSWORD'] || 'password123'
    gitlab_token = ENV['TEST_GITLAB_TOKEN']
    
    # 테스트 저장소 정의
    test_repositories = [
      {
        name: "SVNBook Source (소형)",
        url: "https://svn.code.sf.net/p/svnbook/source/trunk",
        category: "small",
        expected_size_mb: 50,
        expected_commits: 6000,
        gitlab_project_id: ENV['TEST_GITLAB_PROJECT_ID_SMALL']
      },
      {
        name: "Apache Commons Collections (중형)",
        url: "https://svn.apache.org/repos/asf/commons/proper/collections/trunk",
        category: "medium", 
        expected_size_mb: 200,
        expected_commits: 3000,
        gitlab_project_id: ENV['TEST_GITLAB_PROJECT_ID_MEDIUM']
      },
      {
        name: "Apache Subversion (대형)",
        url: "https://svn.apache.org/repos/asf/subversion/trunk",
        category: "large",
        expected_size_mb: 2000,
        expected_commits: 50000,
        gitlab_project_id: ENV['TEST_GITLAB_PROJECT_ID_LARGE']
      }
    ]
    
    puts "=== SVN to GitLab 마이그레이션 테스트 ==="
    puts "테스트 시작: #{Time.current}"
    puts
    
    # 테스트 사용자 준비
    user = User.find_or_create_by(email: test_user_email) do |u|
      u.password = test_user_password
    end
    puts "테스트 사용자: #{user.email} (ID: #{user.id})"
    
    # GitLab 토큰 설정
    if gitlab_token
      gitlab_token_record = user.build_gitlab_token(token: gitlab_token)
      gitlab_token_record.save!
      puts "GitLab 토큰 설정 완료"
    else
      puts "경고: GitLab 토큰이 설정되지 않음 (TEST_GITLAB_TOKEN)"
    end
    
    # 테스트 결과 저장
    results = []
    
    # 계층적 테스트 실행
    test_repositories.each_with_index do |repo_info, index|
      puts "\n=== #{index + 1}단계: #{repo_info[:category].upcase} 저장소 테스트 ==="
      puts "저장소: #{repo_info[:name]}"
      puts "URL: #{repo_info[:url]}"
      puts "예상 크기: ~#{repo_info[:expected_size_mb]}MB"
      puts "예상 커밋: ~#{repo_info[:expected_commits]}"
      
      # 이전 테스트가 실패한 경우 중단
      if index > 0 && results.last[:status] == 'failed'
        puts "이전 테스트 실패로 중단"
        break
      end
      
      # 대형 저장소 확인
      if repo_info[:category] == 'large' && ENV['SKIP_LARGE_TESTS'] != 'false'
        puts "대형 저장소 테스트 건너뜀 (SKIP_LARGE_TESTS=false로 실행 가능)"
        next
      end
      
      result = {}
      
      begin
        # Repository 생성
        repository = nil
        create_time = Benchmark.measure do
          repository = user.repositories.create!(
            name: repo_info[:name],
            svn_url: repo_info[:url],
            gitlab_project_id: repo_info[:gitlab_project_id] || "test-#{repo_info[:category]}",
            migration_method: 'full_history',
            auth_type: 'none'
          )
        end
        
        puts "Repository 생성 완료 (#{create_time.real.round(2)}초)"
        
        # SVN 구조 감지
        detect_time = Benchmark.measure do
          detector = Repositories::SvnStructureDetector.new(repository)
          detection_result = detector.call
          
          if detection_result[:success]
            repository.update!(
              svn_structure: detection_result[:structure],
              authors_mapping: detection_result[:authors].each_with_object({}) do |author, hash|
                hash[author[:svn_name]] = {
                  name: author[:svn_name],
                  email: "#{author[:svn_name]}@example.com"
                }
              end
            )
            
            puts "SVN 구조 감지 성공:"
            puts "  - 레이아웃: #{detection_result[:structure]['layout']}"
            puts "  - 리비전 수: #{detection_result[:structure]['total_revisions']}"
            puts "  - 작성자 수: #{detection_result[:authors].size}"
          else
            puts "SVN 구조 감지 실패: #{detection_result[:error]}"
          end
        end
        
        puts "구조 감지 완료 (#{detect_time.real.round(2)}초)"
        
        # 마이그레이션 작업 생성 및 실행
        job = repository.jobs.create!(
          user: user,
          job_type: 'migration',
          status: 'pending'
        )
        
        puts "마이그레이션 작업 시작 (Job ID: #{job.id})"
        start_time = Time.current
        
        # Sidekiq 작업 실행
        MigrationJob.perform_async(job.id)
        
        # 작업 시작 대기
        sleep 5
        
        # 작업 완료 대기 및 진행률 표시
        loop do
          job.reload
          
          if job.completed? || job.failed?
            break
          end
          
          # 진행률 표시
          if job.total_revisions && job.total_revisions > 0
            progress_percent = (job.current_revision.to_f / job.total_revisions * 100).round(1)
            eta_display = job.formatted_eta || "계산 중..."
            
            print "\r진행률: #{progress_percent}% (#{job.current_revision}/#{job.total_revisions}) - ETA: #{eta_display}"
          else
            print "\r진행 중..."
          end
          
          sleep 5
        end
        
        end_time = Time.current
        duration = end_time - start_time
        
        puts "\n"
        
        if job.completed?
          puts "✅ 마이그레이션 성공!"
          result[:status] = 'success'
        else
          puts "❌ 마이그레이션 실패!"
          puts "오류: #{job.error_log}"
          result[:status] = 'failed'
        end
        
        # 결과 저장
        result.merge!({
          repository_name: repo_info[:name],
          category: repo_info[:category],
          duration_seconds: duration.to_i,
          duration_display: "#{(duration / 60).to_i}분 #{(duration % 60).to_i}초",
          final_status: job.status,
          total_revisions: job.total_revisions,
          error_log: job.error_log
        })
        
        # 저장소 크기 확인
        if job.completed? && repository.local_git_path && Dir.exist?(repository.local_git_path)
          size_mb = `du -sm #{repository.local_git_path}`.split.first.to_i
          result[:actual_size_mb] = size_mb
          puts "실제 크기: #{size_mb}MB (예상: ~#{repo_info[:expected_size_mb]}MB)"
        end
        
      rescue => e
        puts "❌ 오류 발생: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        result[:status] = 'error'
        result[:error] = e.message
      end
      
      results << result
    end
    
    # 최종 결과 요약
    puts "\n=== 테스트 결과 요약 ==="
    puts "테스트 완료: #{Time.current}"
    puts
    
    results.each do |result|
      puts "#{result[:repository_name]}:"
      puts "  상태: #{result[:status]}"
      puts "  소요 시간: #{result[:duration_display]}" if result[:duration_display]
      puts "  실제 크기: #{result[:actual_size_mb]}MB" if result[:actual_size_mb]
      puts "  리비전 수: #{result[:total_revisions]}" if result[:total_revisions]
      puts "  오류: #{result[:error] || result[:error_log]}" if result[:status] != 'success'
      puts
    end
    
    success_count = results.count { |r| r[:status] == 'success' }
    puts "성공: #{success_count}/#{results.size}"
    
    # 결과를 파일로 저장
    File.write(
      "test_results_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json",
      JSON.pretty_generate(results)
    )
  end
  
  desc "테스트 데이터 정리"
  task cleanup: :environment do
    puts "테스트 데이터 정리 중..."
    
    test_user = User.find_by(email: ENV['TEST_USER_EMAIL'] || 'test@example.com')
    if test_user
      # 로컬 Git 저장소 삭제
      test_user.repositories.each do |repo|
        if repo.local_git_path && Dir.exist?(repo.local_git_path)
          puts "저장소 삭제: #{repo.local_git_path}"
          FileUtils.rm_rf(repo.local_git_path)
        end
      end
      
      # 데이터베이스 레코드 삭제
      test_user.destroy
      puts "테스트 사용자 및 관련 데이터 삭제 완료"
    else
      puts "테스트 사용자를 찾을 수 없음"
    end
  end
end