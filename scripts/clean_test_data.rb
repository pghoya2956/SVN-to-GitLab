# 테스트 데이터 정리 스크립트
puts "Cleaning test data..."

# 테스트 사용자 제거 (메인 사용자 제외)
test_users = User.where.not(email: 'ghdi7662@gmail.com')
puts "Removing #{test_users.count} test users..."
test_users.destroy_all

# 모든 Job 제거
puts "Removing #{Job.count} jobs..."
Job.destroy_all

# 모든 Repository 제거
puts "Removing #{Repository.count} repositories..."
Repository.destroy_all

# GitLab 토큰 정리 (메인 사용자 토큰은 유지하되 테스트 토큰 제거)
main_user = User.find_by(email: 'ghdi7662@gmail.com')
if main_user && main_user.gitlab_token
  main_user.gitlab_token.update!(token: nil)
  puts "Cleared GitLab token for main user"
end

puts "Test data cleaned successfully!"