require 'test_helper'

class GitSvnMigrationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in @user
    
    # 테스트 SVN 저장소 설정
    @test_svn_url = "https://svn.code.sf.net/p/svnbook/source"
  end
  
  test "전체 이력 마이그레이션 - 표준 레이아웃" do
    # 1. Repository 생성
    repository = create_test_repository(
      svn_url: @test_svn_url,
      migration_method: 'full_history'
    )
    
    # 2. SVN 구조 감지
    detector = Repositories::SvnStructureDetector.new(repository)
    result = detector.call
    
    assert result[:success]
    assert result[:structure][:trunk][:exists]
    assert result[:structure][:branches][:exists]
    assert result[:structure][:tags][:exists]
    
    # 3. Authors 추출
    assert result[:authors].any?
    
    # 4. 마이그레이션 실행
    job = repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'pending'
    )
    
    MigrationJob.new.perform(job.id)
    
    # 5. 검증
    job.reload
    assert_equal 'completed', job.status
    assert repository.local_git_path.present?
    assert File.directory?(repository.local_git_path)
    
    # Git 저장소 검증
    Dir.chdir(repository.local_git_path) do
      # 커밋 수 확인
      commit_count = `git rev-list --count --all`.to_i
      assert commit_count > 100
      
      # 브랜치 확인
      branches = `git branch -a`.lines.map(&:strip)
      assert branches.any? { |b| b.include?('main') }
      
      # Authors 확인
      authors = `git log --format='%an <%ae>' | sort -u`.lines
      assert authors.any?
    end
  end
  
  test "증분 동기화" do
    # 이미 마이그레이션된 저장소
    repository = repositories(:migrated)
    
    # 초기 리비전 저장
    initial_revision = repository.last_synced_revision
    
    # 증분 동기화 실행
    job = repository.jobs.create!(
      user: @user,
      job_type: 'incremental_sync',
      status: 'pending'
    )
    
    IncrementalSyncJob.new.perform(repository.id)
    
    # 검증
    job.reload
    assert_equal 'completed', job.status
    
    repository.reload
    assert repository.last_synced_revision >= initial_revision
  end
  
  test "대용량 저장소 처리" do
    # Apache Subversion (2GB+)
    large_repo = create_test_repository(
      svn_url: "https://svn.apache.org/repos/asf/subversion",
      migration_method: 'full_history'
    )
    
    # 부분 마이그레이션 (최근 100 리비전만)
    large_repo.update!(revision_limit: 100)
    
    job = run_migration(large_repo)
    
    assert_equal 'completed', job.status
    
    Dir.chdir(large_repo.local_git_path) do
      commit_count = `git rev-list --count --all`.to_i
      assert commit_count <= 100
    end
  end
  
  test "인코딩 처리" do
    # 다양한 인코딩이 포함된 저장소
    repository = create_test_repository(
      svn_url: @test_svn_url,
      migration_method: 'full_history'
    )
    
    job = run_migration(repository)
    
    # UTF-8로 정상 변환 확인
    Dir.chdir(repository.local_git_path) do
      log = `git log --oneline`
      assert log.valid_encoding?
      assert_equal 'UTF-8', log.encoding.name
    end
  end
  
  private
  
  def create_test_repository(attributes)
    Repository.create!(
      user: @user,
      name: "Test Repository",
      gitlab_project_id: 12345,
      **attributes
    )
  end
  
  def run_migration(repository)
    job = repository.jobs.create!(
      user: @user,
      job_type: 'migration',
      status: 'pending'
    )
    
    MigrationJob.new.perform(job.id)
    job.reload
  end
end