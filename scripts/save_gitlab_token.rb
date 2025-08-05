user = User.find_by(email: 'test@example.com')
if user.gitlab_token
  user.gitlab_token.update!(token: 'glpat-SvhybvwSBFGkKgGxVsr-')
else
  user.create_gitlab_token!(token: 'glpat-SvhybvwSBFGkKgGxVsr-')
end
puts 'GitLab 토큰 저장 완료'