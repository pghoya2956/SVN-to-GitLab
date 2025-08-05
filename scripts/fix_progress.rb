job = Job.find(14)

# 최신 리비전 찾기
if job.output_log
  last_revision_line = job.output_log.lines.reverse.find { |line| line =~ /r(\d+) = / }
  if last_revision_line && last_revision_line =~ /r(\d+) = /
    current_rev = $1.to_i
    puts "실제 현재 리비전: #{current_rev}"
    puts "DB의 현재 리비전: #{job.current_revision}"
    
    # 수동으로 업데이트
    job.update!(current_revision: current_rev)
    job.update_progress!
    
    puts "업데이트 후:"
    puts "  현재 리비전: #{job.current_revision}"
    puts "  진행률: #{job.progress}%"
  end
end

# Job 13도 확인
puts "\n=== Job #13 확인 ==="
job13 = Job.find(13)
if job13.output_log
  last_revision_line = job13.output_log.lines.reverse.find { |line| line =~ /r(\d+) = / }
  if last_revision_line && last_revision_line =~ /r(\d+) = /
    current_rev = $1.to_i
    puts "Job 13 실제 현재 리비전: #{current_rev}"
    puts "Job 13 DB의 현재 리비전: #{job13.current_revision}"
    
    # total_revisions 업데이트 필요
    if current_rev > job13.total_revisions
      job13.update!(total_revisions: current_rev + 100)
    end
    
    job13.update!(current_revision: current_rev)
    job13.update_progress!
    
    puts "업데이트 후:"
    puts "  현재 리비전: #{job13.current_revision}"
    puts "  전체 리비전: #{job13.total_revisions}"
    puts "  진행률: #{job13.progress}%"
  end
end