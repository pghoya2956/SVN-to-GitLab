# Create test user
User.find_or_create_by!(email: 'ghdi7662@gmail.com') do |user|
  user.password = 'password123'
  user.password_confirmation = 'password123'
end

puts "Test user created: ghdi7662@gmail.com / password123"