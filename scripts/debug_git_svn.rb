#!/usr/bin/env ruby

# git svn 명령어 디버깅 스크립트

require 'open3'
require 'fileutils'

puts "=== Git SVN 디버깅 ==="

# 테스트 디렉토리 생성
test_dir = "/tmp/svn_test_#{Time.now.to_i}"
FileUtils.mkdir_p(test_dir)
puts "테스트 디렉토리: #{test_dir}"

# 간단한 git svn 명령 테스트
svn_url = "https://svn.code.sf.net/p/svnbook/source/trunk"
cmd = ['git', 'svn', 'clone', '--no-metadata', '--verbose', svn_url, test_dir]

puts "\n실행 명령어:"
puts cmd.join(' ')

puts "\n실행 중..."
stdout_str, stderr_str, status = Open3.capture3(*cmd)

puts "\n종료 코드: #{status.exitstatus}"
puts "\n표준 출력:"
puts stdout_str

puts "\n표준 오류:"
puts stderr_str

# 버전 확인
puts "\n=== 버전 정보 ==="
puts "Git 버전:"
system("git --version")

puts "\nGit-SVN 확인:"
system("git svn --version")

# 정리
FileUtils.rm_rf(test_dir) if Dir.exist?(test_dir)
puts "\n테스트 디렉토리 정리 완료"