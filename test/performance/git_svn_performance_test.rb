require 'test_helper'
require 'benchmark'

class GitSvnPerformanceTest < ActiveSupport::TestCase
  test "마이그레이션 성능 측정" do
    results = {}
    
    # 소형 저장소 (< 1000 커밋)
    results[:small] = benchmark_migration(
      "https://svn.code.sf.net/p/svnbook/source/trunk",
      expected_commits: 1000
    )
    
    # 중형 저장소 (< 10000 커밋)
    results[:medium] = benchmark_migration(
      "https://svn.apache.org/repos/asf/commons/proper/collections/trunk",
      expected_commits: 10000
    )
    
    # 결과 출력
    puts "\n=== 성능 테스트 결과 ==="
    results.each do |size, data|
      puts "#{size.to_s.capitalize} Repository:"
      puts "  Time: #{data[:time].round(2)}s"
      puts "  Commits: #{data[:commits]}"
      puts "  Speed: #{(data[:commits] / data[:time]).round(2)} commits/sec"
    end
    
    # 성능 기준 검증
    assert results[:small][:time] < 300  # 5분 이내
    assert results[:medium][:time] < 1800 # 30분 이내
  end
  
  private
  
  def benchmark_migration(svn_url, expected_commits:)
    repository = Repository.create!(
      user: users(:one),
      name: "Performance Test",
      svn_url: svn_url,
      gitlab_project_id: 99999,
      migration_method: 'full_history'
    )
    
    time = Benchmark.realtime do
      job = repository.jobs.create!(
        user: users(:one),
        job_type: 'migration',
        status: 'pending'
      )
      
      MigrationJob.new.perform(job.id)
    end
    
    commit_count = Dir.chdir(repository.local_git_path) do
      `git rev-list --count --all`.to_i
    end
    
    { time: time, commits: commit_count }
  ensure
    # Cleanup
    FileUtils.rm_rf(repository.local_git_path) if repository&.local_git_path
  end
end